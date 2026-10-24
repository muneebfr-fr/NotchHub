import AppKit
import ApplicationServices
import Combine
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// GlassDock: window previews for the real macOS Dock. The Dock itself is untouched; this only adds a panel of
/// live window cards above whichever app icon is hovered.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PreviewPanel!
    private let previews = PreviewModel()
    private let watcher = DockWatcher()
    private var switcher: Switcher?
    private var hoveredIcon: DockIcon?
    private var showWork: DispatchWorkItem?
    private var outsideSince: Date?
    private var cancellables: Set<AnyCancellable> = []

    // File-drag tracking for spring-loaded previews.
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var fileDragActive = false
    private var dragIcons: [DockIcon] = []
    private var dragIconsAt = Date.distantPast
    private var springAnchor: (id: CGWindowID, point: CGPoint, since: Date)?

    private static let panelHeight: CGFloat = 240

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Older versions hid the Dock; make sure the real one is back.
        SystemDock.restore()

        if !AXIsProcessTrusted() {
            // Needed to follow the Dock's hover and to focus the chosen window.
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: PreviewsView().environmentObject(previews))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()

        switcher = Switcher()
        watcher.onHover = { [weak self] icon in self?.dockHoverChanged(icon) }
        previews.onSpringLoaded = { [weak self] in self?.hidePreviews() }
        previews.$thumbnails
            .receive(on: RunLoop.main)
            .sink { [weak self] thumbs in
                MainActor.assumeIsolated { if thumbs.isEmpty { self?.panel.ignoresMouseEvents = true } }
            }
            .store(in: &cancellables)

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event)
            return event
        }
        // A new drag session bumps the drag pasteboard's change count; a button release ends it.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .leftMouseDown { self.dragChangeCount = NSPasteboard(name: .drag).changeCount }
                if type == .leftMouseUp { self.endFileDrag() }
            }
        }
        // Lets the hide grace period (and a resting drag's spring) complete while the cursor is still.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.previews.appID != nil || self.fileDragActive else { return }
                self.mouseMoved()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.endFileDrag() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemDock.restore()
    }

    // MARK: Hover

    private func dockHoverChanged(_ icon: DockIcon?) {
        guard let icon else {
            hoveredIcon = nil
            showWork?.cancel()
            return
        }
        hoveredIcon = icon
        guard let path = icon.appPath, isRunning(path) else {
            showWork?.cancel()
            if previews.appID != nil { hidePreviews() }
            return
        }
        previews.prepare(appPath: path)
        // Moving between icons while previews are up switches instantly; the first one waits a moment.
        if previews.appID != nil {
            present(path, above: icon)
            return
        }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoveredIcon?.appPath == path else { return }
                self.present(path, above: icon)
            }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func isRunning(_ path: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }

    /// Places the panel just above the icon (which may be magnified) and shows that app's windows.
    private func present(_ path: String, above icon: DockIcon) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.frame.midX, y: icon.frame.midY)) } ?? NSScreen.main!
        panel.setFrame(CGRect(x: screen.frame.minX, y: icon.frame.maxY + 6, width: screen.frame.width, height: Self.panelHeight), display: false)
        previews.anchorX = icon.frame.midX - screen.frame.minX
        outsideSince = nil
        previews.show(appPath: path)
    }

    private func hidePreviews() {
        showWork?.cancel()
        outsideSince = nil
        previews.hide()
        panel.ignoresMouseEvents = true
    }

    /// The preview cards' frame on screen.
    private var cardsRect: CGRect {
        let row = previews.rowRect
        return CGRect(x: panel.frame.minX + row.minX, y: panel.frame.maxY - row.maxY, width: row.width, height: row.height)
    }

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation
        trackFileDrag(mouse)
        guard previews.appID != nil else { return }

        // Stays open over the cards, over the hovered icon, and across the small gap between them.
        let cards = cardsRect.insetBy(dx: -14, dy: -14)
        let bridge = hoveredIcon.map { icon -> CGRect in
            let minX = min(icon.frame.minX, cards.minX), maxX = max(icon.frame.maxX, cards.maxX)
            return CGRect(x: minX, y: icon.frame.minY, width: maxX - minX, height: max(1, cards.minY - icon.frame.minY + 1))
        } ?? .null
        let overCards = !previews.thumbnails.isEmpty && cards.contains(mouse)
        panel.ignoresMouseEvents = !overCards

        if overCards || hoveredIcon != nil || bridge.contains(mouse) || fileDragActive {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.3 { hidePreviews() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: Spring-loaded previews

    private func trackFileDrag(_ mouse: CGPoint) {
        if !fileDragActive {
            let pasteboard = NSPasteboard(name: .drag)
            guard NSEvent.pressedMouseButtons & 1 == 1, pasteboard.changeCount != dragChangeCount,
                  let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let first = urls.first
            else { return }
            fileDragActive = true
            previews.dragIcon = NSWorkspace.shared.icon(forFile: first.path)
        }

        // While dragging, the Dock doesn't report hover, so icons are hit-tested directly (frames refreshed
        // a few times a second as the Dock magnifies).
        if Date().timeIntervalSince(dragIconsAt) > 0.25 {
            dragIcons = watcher.appIcons()
            dragIconsAt = Date()
        }
        let underCursor = dragIcons.first { $0.frame.insetBy(dx: -2, dy: -6).contains(mouse) }
        if let icon = underCursor, icon.appPath != hoveredIcon?.appPath {
            dockHoverChanged(icon)
        } else if underCursor == nil, hoveredIcon != nil {
            hoveredIcon = nil
        }

        guard !previews.thumbnails.isEmpty else { return }
        // Mouse position in the previews overlay's top-left coordinates.
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        guard let (id, frame) = previews.imageFrames.first(where: { id, frame in
            frame.contains(local) && previews.thumbnails.contains { $0.id == id }
        }) else {
            if previews.dragMarker != nil { previews.dragMarker = nil }
            springAnchor = nil
            return
        }
        let point = CGPoint(x: local.x - frame.minX, y: local.y - frame.minY)
        previews.dragMarker = (id, point)

        // Springs once the drag rests on one spot for a moment.
        if let anchor = springAnchor, anchor.id == id, hypot(anchor.point.x - point.x, anchor.point.y - point.y) < 8 {
            if Date().timeIntervalSince(anchor.since) > 0.55,
               let thumbnail = previews.thumbnails.first(where: { $0.id == id }) {
                springAnchor = nil
                previews.dragMarker = nil
                previews.springLoad(thumbnail, at: CGPoint(x: point.x / frame.width, y: point.y / frame.height))
            }
        } else {
            springAnchor = (id, point, Date())
        }
    }

    private func endFileDrag() {
        guard fileDragActive else { return }
        fileDragActive = false
        springAnchor = nil
        dragIcons = []
        previews.dragMarker = nil
        previews.dragIcon = nil
    }
}
