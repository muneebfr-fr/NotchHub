import AppKit
import ApplicationServices
import SwiftUI

struct DockApp: Identifiable, Equatable {
    let id: String
    let url: URL
    let name: String
    let icon: NSImage
    var pinned: Bool
    var running: Bool
    var active: Bool
    var launching: Bool
    var badge: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.pinned == rhs.pinned && lhs.running == rhs.running
            && lhs.active == rhs.active && lhs.launching == rhs.launching && lhs.badge == rhs.badge
    }
}

@MainActor
final class DockModel: ObservableObject {
    @Published private(set) var pinned: [DockApp] = []
    @Published private(set) var others: [DockApp] = []
    @Published private(set) var trashFull = false

    /// Native Dock sizes, copied from the user's Dock settings.
    let tileSize: CGFloat
    let largeSize: CGFloat
    let magnifies: Bool

    private static let pinnedKey = "pinnedApps"
    private var pinnedPaths: [String]
    private var icons: [String: NSImage] = [:]
    private var launching: Set<String> = []
    private var badges: [String: String] = [:]
    private var badgeTimer: Timer?

    init() {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let tile = dock?.double(forKey: "tilesize") ?? 0
        let large = dock?.double(forKey: "largesize") ?? 0
        tileSize = tile > 0 ? tile : 48
        largeSize = large > 0 ? large : 72
        magnifies = dock?.object(forKey: "magnification") as? Bool ?? false

        pinnedPaths = Self.deduplicated((UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? Self.importSystemDock()).map(Self.resolve))
        UserDefaults.standard.set(pinnedPaths, forKey: Self.pinnedKey)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.willLaunchApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let event = note.name
                MainActor.assumeIsolated { self?.workspaceEvent(event, app: app) }
            }
        }
        rebuild()
    }

    /// The user's existing Dock apps, in order (spacers skipped), with Finder first like the real Dock.
    private static func importSystemDock() -> [String] {
        let apps = (UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        let paths = apps.compactMap { tile -> String? in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String,
                  let url = URL(string: string)
            else { return nil }
            return url.path
        }
        return ["/System/Library/CoreServices/Finder.app"] + paths.filter { !$0.hasSuffix("Finder.app") }
    }

    /// Dock items can be Finder aliases (e.g. one kept in a Documents folder); the native Dock follows them to the app.
    private static func resolve(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return ((try? URL(resolvingAliasFileAt: url)) ?? url).resolvingSymlinksInPath().path
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func workspaceEvent(_ name: Notification.Name, app: NSRunningApplication?) {
        if name == NSWorkspace.willLaunchApplicationNotification, let path = app?.bundleURL?.path {
            launching.insert(path)
        } else if name == NSWorkspace.didLaunchApplicationNotification, let path = app?.bundleURL?.path {
            // Keep bouncing briefly after launch, like the native Dock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    self?.launching.remove(path)
                    self?.rebuild()
                }
            }
        }
        rebuild()
    }

    func rebuild() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil && $0.processIdentifier != getpid()
        }
        let runningPaths = Set(running.compactMap { $0.bundleURL?.path })
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleURL?.path

        func make(_ path: String, pinned: Bool) -> DockApp? {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let name = (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
            return DockApp(
                id: path, url: url, name: name, icon: icon(for: path), pinned: pinned,
                running: runningPaths.contains(path) || path.hasSuffix("Finder.app"),
                active: path == frontmost,
                launching: launching.contains(path), badge: badges[name]
            )
        }

        let newPinned = pinnedPaths.compactMap { make($0, pinned: true) }
        let pinnedSet = Set(pinnedPaths)
        let newOthers = running
            .compactMap { $0.bundleURL?.path }
            .filter { !pinnedSet.contains($0) }
            .compactMap { make($0, pinned: false) }

        if newPinned != pinned { pinned = newPinned }
        if newOthers != others { others = newOthers }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let full = ((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.filter { $0 != ".DS_Store" }.isEmpty == false)
        if full != trashFull { trashFull = full }
    }

    private func icon(for path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        // Drawn once into a bitmap at the largest size it's ever shown (Retina), so magnifying only scales pixels.
        let source = NSWorkspace.shared.icon(forFile: path)
        let pixels = Int(ceil(largeSize * 2))
        let image: NSImage
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = NSSize(width: largeSize, height: largeSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: largeSize, height: largeSize))
            NSGraphicsContext.restoreGraphicsState()
            image = NSImage(size: rep.size)
            image.addRepresentation(rep)
        } else {
            image = source
        }
        icons[path] = image
        return image
    }

    // MARK: Actions

    /// Same as clicking a Dock icon: launch, or activate and reopen a window if it has none.
    func open(_ app: DockApp) {
        if !app.running { launching.insert(app.id); rebuild() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
    }

    func open(_ files: [URL], with app: DockApp) {
        NSWorkspace.shared.open(files, withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    func setPinned(_ app: DockApp, _ pin: Bool) {
        if pin, !pinnedPaths.contains(app.id) { pinnedPaths.append(app.id) }
        if !pin { pinnedPaths.removeAll { $0 == app.id } }
        UserDefaults.standard.set(pinnedPaths, forKey: Self.pinnedKey)
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { rebuild() }
    }

    func move(_ app: DockApp, before target: DockApp?) {
        guard let from = pinnedPaths.firstIndex(of: app.id) else { return }
        pinnedPaths.remove(at: from)
        let to = target.flatMap { pinnedPaths.firstIndex(of: $0.id) } ?? pinnedPaths.count
        pinnedPaths.insert(app.id, at: to)
        UserDefaults.standard.set(pinnedPaths, forKey: Self.pinnedKey)
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { rebuild() }
    }

    func quit(_ app: DockApp) {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.id }?.terminate()
    }

    func showInFinder(_ app: DockApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    /// Dropping files on the Trash moves them there (Finder's own behaviour; nothing is permanently deleted).
    func trash(_ files: [URL]) {
        NSWorkspace.shared.recycle(files)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    // MARK: Badges

    /// Unread counts come from the (hidden) system Dock, which still tracks them. Polled only while visible.
    func setBadgePolling(_ on: Bool) {
        badgeTimer?.invalidate()
        badgeTimer = nil
        guard on else { return }
        readBadges()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBadges() }
        }
    }

    private func readBadges() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        var found: [String: String] = [:]
        for list in Self.children(AXUIElementCreateApplication(dock.processIdentifier)) {
            for item in Self.children(list) {
                guard let title = Self.string(item, kAXTitleAttribute),
                      let label = Self.string(item, "AXStatusLabel"), !label.isEmpty
                else { continue }
                found[title] = label
            }
        }
        if found != badges {
            badges = found
            rebuild()
        }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
