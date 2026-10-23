import AppKit
import ApplicationServices
import ScreenCaptureKit

/// A minimised window shown on the right of the dock, like the native Dock.
struct MinimizedWindow: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let title: String
    let appIcon: NSImage
    let element: AXUIElement
    var thumbnail: NSImage?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && (lhs.thumbnail == nil) == (rhs.thumbnail == nil) }
}

/// The extra, non-app parts of the dock: minimised windows, the Downloads stack, login items and desktop assignment.
@MainActor
final class DockExtras: ObservableObject {
    @Published private(set) var minimized: [MinimizedWindow] = []
    @Published private(set) var recentDownloads: [URL] = []
    private(set) var loginItemPaths: Set<String> = []
    private var thumbnailCache: [String: NSImage] = [:]

    nonisolated static let downloadsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

    // MARK: Minimised windows

    /// Scanned when the dock appears and after app changes (cheap: a few Accessibility calls per app).
    func refreshMinimized() {
        guard AXIsProcessTrusted() else { return }
        var found: [MinimizedWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement]
            else { continue }
            for window in windows {
                var minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                guard (minimized as? Bool) == true else { continue }
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                let name = title as? String ?? app.localizedName ?? "Window"
                let id = "\(app.processIdentifier)-\(name)"
                found.append(MinimizedWindow(
                    id: id, pid: app.processIdentifier, title: name,
                    appIcon: app.icon ?? NSImage(), element: window, thumbnail: thumbnailCache[id]
                ))
            }
        }
        if found != minimized { minimized = found }
        captureThumbnails(for: found.filter { $0.thumbnail == nil })
    }

    /// macOS keeps a snapshot of minimised windows; when it can be captured it's used instead of the app icon.
    private func captureThumbnails(for windows: [MinimizedWindow]) {
        guard !windows.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            for window in windows {
                guard let match = content.windows.first(where: {
                    $0.owningApplication?.processID == window.pid && ($0.title ?? "") == window.title && $0.windowLayer == 0
                }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1, 200 / max(match.frame.width, 1))
                config.width = Int(match.frame.width * scale * 2)
                config.height = Int(match.frame.height * scale * 2)
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: match), configuration: config
                ) else { continue }
                let thumb = NSImage(cgImage: image, size: NSSize(width: match.frame.width * scale, height: match.frame.height * scale))
                guard let self else { return }
                self.thumbnailCache[window.id] = thumb
                if let index = self.minimized.firstIndex(where: { $0.id == window.id }) {
                    self.minimized[index].thumbnail = thumb
                }
            }
        }
    }

    func restore(_ window: MinimizedWindow) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.pid) { DockModel.bringForward(app) }
        minimized.removeAll { $0.id == window.id }
    }

    // MARK: Downloads stack

    /// Most recently added files, looking one level into folders (NotchHub sorts Downloads into type folders).
    func refreshDownloads() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .isDirectoryKey, .isPackageKey]
        var files: [(URL, Date)] = []
        func scan(_ folder: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for url in items {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true, values?.isPackage != true {
                    if depth < 1, url.lastPathComponent != "Old" { scan(url, depth: depth + 1) }
                } else {
                    files.append((url, values?.addedToDirectoryDate ?? .distantPast))
                }
            }
        }
        scan(Self.downloadsFolder, depth: 0)
        let recent = files.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
        if recent != recentDownloads { recentDownloads = recent }
    }

    // MARK: Login items (via System Events, cached so menus never wait on it)

    func refreshLoginItems() {
        Task.detached {
            let output = Self.osascript(#"tell application "System Events" to get the path of every login item"#)
            let paths = Set((output ?? "").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            await MainActor.run { [weak self] in self?.loginItemPaths = paths }
        }
    }

    func setOpenAtLogin(_ app: DockApp, _ on: Bool) {
        let path = app.url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = on
            ? #"tell application "System Events" to make login item at end with properties {path:"\#(path)", hidden:false}"#
            : #"tell application "System Events" to delete (every login item whose path is "\#(path)")"#
        if on { loginItemPaths.insert(app.url.path) } else { loginItemPaths.remove(app.url.path) }
        Task.detached {
            _ = Self.osascript(script)
            await MainActor.run { [weak self] in self?.refreshLoginItems() }
        }
    }

    nonisolated private static func osascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: Desktop assignment (the same setting the native Dock's Options menu writes)

    enum Assignment { case none, allDesktops, thisDesktop }

    func assignment(for app: DockApp) -> Assignment {
        guard let id = Bundle(url: app.url)?.bundleIdentifier?.lowercased(),
              let bindings = CFPreferencesCopyAppValue("app-bindings" as CFString, "com.apple.spaces" as CFString) as? [String: String],
              let value = bindings[id]
        else { return .none }
        return value == "AllSpaces" ? .allDesktops : .thisDesktop
    }

    func assign(_ app: DockApp, to assignment: Assignment) {
        guard let id = Bundle(url: app.url)?.bundleIdentifier?.lowercased() else { return }
        var bindings = (CFPreferencesCopyAppValue("app-bindings" as CFString, "com.apple.spaces" as CFString) as? [String: String]) ?? [:]
        switch assignment {
        case .none: bindings[id] = nil
        case .allDesktops: bindings[id] = "AllSpaces"
        case .thisDesktop:
            guard let uuid = Self.currentSpaceUUID() else { return }
            bindings[id] = uuid
        }
        CFPreferencesSetAppValue("app-bindings" as CFString, bindings as CFDictionary, "com.apple.spaces" as CFString)
        CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
        // The system Dock (still running, hidden) owns Spaces and reads this on restart.
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }

    private static func currentSpaceUUID() -> String? {
        guard let config = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString) as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]]
        else { return nil }
        for monitor in monitors {
            if let current = monitor["Current Space"] as? [String: Any], let uuid = current["uuid"] as? String, !uuid.isEmpty {
                return uuid
            }
        }
        return nil
    }
}
