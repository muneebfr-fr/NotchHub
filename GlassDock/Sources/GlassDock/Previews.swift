import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

struct WindowThumbnail: Identifiable {
    let id: CGWindowID
    let title: String
    let image: NSImage
    let pid: pid_t
}

/// Live window previews for the hovered app, captured on demand (nothing runs when no preview is showing).
@MainActor
final class PreviewModel: ObservableObject {
    @Published private(set) var appID: String?
    @Published private(set) var thumbnails: [WindowThumbnail] = []
    /// Horizontal centre of the hovered icon, in the previews overlay's coordinates.
    @Published var anchorX: CGFloat = 0
    /// The cards' frame, in the overlay's top-left coordinates (not published: never triggers a render).
    var rowRect: CGRect = .zero

    private var cache: [String: (at: Date, thumbnails: [WindowThumbnail])] = [:]
    private var loading: [String: Task<Void, Never>] = [:]

    /// Starts capturing as soon as an icon is hovered, so previews are usually ready when they're shown.
    func prepare(_ app: DockApp) {
        guard app.running, loading[app.id] == nil else { return }
        if let cached = cache[app.id], Date().timeIntervalSince(cached.at) < 2 { return }
        let id = app.id
        loading[id] = Task { [weak self] in
            let thumbs = await Self.capture(appPath: id)
            guard let self else { return }
            self.loading[id] = nil
            self.cache[id] = (Date(), thumbs)
            if self.appID == id {
                withAnimation(.spring(duration: 0.35, bounce: 0.12)) { self.thumbnails = thumbs }
            }
        }
    }

    func show(for app: DockApp) {
        guard appID != app.id else { return }
        appID = app.id
        // Cached thumbnails appear instantly and are refreshed in the background.
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) { thumbnails = cache[app.id]?.thumbnails ?? [] }
        prepare(app)
    }

    func hide() {
        guard appID != nil else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            appID = nil
            thumbnails = []
        }
    }

    private static func capture(appPath: String) async -> [WindowThumbnail] {
        let content: SCShareableContent
        do {
            // Includes windows on other desktops and minimised ones, not just what's on screen now.
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            NSLog("GlassDock: window previews unavailable (Screen Recording permission?): \(error.localizedDescription)")
            return []
        }
        let windows = content.windows.filter {
            $0.owningApplication.flatMap { app in
                NSRunningApplication(processIdentifier: app.processID)?.bundleURL?.path
            } == appPath && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
                && ($0.isOnScreen || !($0.title ?? "").isEmpty)
        }
        // All windows are captured in parallel.
        return await withTaskGroup(of: (Int, WindowThumbnail?).self) { group in
            for (index, window) in windows.prefix(6).enumerated() {
                group.addTask {
                    let config = SCStreamConfiguration()
                    let scale = min(1, 360 / max(window.frame.width, 1))
                    config.width = Int(window.frame.width * scale * 2)
                    config.height = Int(window.frame.height * scale * 2)
                    config.showsCursor = false
                    guard let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
                    ) else { return (index, nil) }
                    return (index, WindowThumbnail(
                        id: window.windowID,
                        title: window.title ?? "",
                        image: NSImage(cgImage: image, size: NSSize(width: window.frame.width * scale, height: window.frame.height * scale)),
                        pid: window.owningApplication?.processID ?? 0
                    ))
                }
            }
            var results: [(Int, WindowThumbnail)] = []
            for await (index, thumb) in group { if let thumb { results.append((index, thumb)) } }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Brings one specific window to the front.
    func focus(_ thumbnail: WindowThumbnail) {
        NSRunningApplication(processIdentifier: thumbnail.pid)?.activate()
        let app = AXUIElementCreateApplication(thumbnail.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            if (title as? String ?? "") == thumbnail.title {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
        hide()
    }
}
