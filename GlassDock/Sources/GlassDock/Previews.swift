import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

struct WindowThumbnail: Identifiable {
    let id: CGWindowID
    let title: String
    let image: NSImage
    let pid: pid_t
    /// The window's frame in top-left global coordinates (valid on any desktop).
    let frame: CGRect
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
    func prepare(appPath id: String) {
        guard loading[id] == nil else { return }
        if let cached = cache[id], Date().timeIntervalSince(cached.at) < 2 { return }
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

    func show(appPath id: String) {
        guard appID != id else { return }
        appID = id
        // Cached thumbnails appear instantly and are refreshed in the background.
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) { thumbnails = cache[id]?.thumbnails ?? [] }
        prepare(appPath: id)
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
                        pid: window.owningApplication?.processID ?? 0,
                        frame: window.frame
                    ))
                }
            }
            var results: [(Int, WindowThumbnail)] = []
            for await (index, thumb) in group { if let thumb { results.append((index, thumb)) } }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Where a dragged file is over a card: card ID and point in that card's thumbnail (top-left, points).
    @Published var dragMarker: (id: CGWindowID, point: CGPoint)?
    var dragIcon: NSImage?
    /// Each thumbnail image's frame in the overlay's top-left coordinates (not published).
    var imageFrames: [CGWindowID: CGRect] = [:]

    /// Called after a drag springs a window open, so the dock can get out of the way.
    var onSpringLoaded: (() -> Void)?

    /// Brings one specific window to the front.
    func focus(_ thumbnail: WindowThumbnail) {
        WindowFocus.focus(windowID: thumbnail.id, pid: thumbnail.pid, title: thumbnail.title)
        hide()
    }

    /// Spring-loading: while a file is dragged over a preview, bring that window forward and move the cursor to
    /// the matching spot in it (`fraction` is the drag position within the thumbnail, 0…1 from the top left),
    /// so the user's own release drops the file exactly where they aimed.
    func springLoad(_ thumbnail: WindowThumbnail, at fraction: CGPoint) {
        WindowFocus.focus(windowID: thumbnail.id, pid: thumbnail.pid, title: thumbnail.title)
        let frame = thumbnail.frame
        let target = CGPoint(
            x: frame.minX + frame.width * min(max(fraction.x, 0.02), 0.98),
            y: frame.minY + frame.height * min(max(fraction.y, 0.02), 0.98)
        )
        hide()
        onSpringLoaded?()
        // Accessibility and CoreGraphics share top-left global coordinates.
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Files dropped straight onto a card (before it springs) open in that app.
    func openDropped(_ urls: [URL], in thumbnail: WindowThumbnail) {
        guard let app = NSRunningApplication(processIdentifier: thumbnail.pid)?.bundleURL else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        hide()
    }

}
