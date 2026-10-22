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

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: DockPanel!
    private var strip: DockStrip!
    private var previewsHost: NSView!
    private let model = DockModel()
    private let previews = PreviewModel()
    private var visible = false
    private var outsideSince: Date?
    private var hoverWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellables: Set<AnyCancellable> = []

    private static let panelHeight: CGFloat = 330
    private static let previewsBottom: CGFloat = 100
    private var stripHeight: CGFloat { Self.previewsBottom }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SystemDock.hide()
        restoreOnSignals()

        if !AXIsProcessTrusted() {
            // Needed to bring a specific window forward from its preview and to read unread badges.
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let container = NSView()
        container.wantsLayer = true
        strip = DockStrip(model: model)
        container.addSubview(strip)
        let host = NSHostingView(rootView: PreviewsView().environmentObject(previews))
        host.sizingOptions = []
        container.addSubview(host)
        previewsHost = host
        panel.contentView = container
        // Hidden views are skipped by layout passes, so the dock's frame updates never touch SwiftUI.
        host.isHidden = true
        position()
        strip.alphaValue = 0
        panel.orderFrontRegardless()

        strip.onHoverChange = { [weak self] item in self?.hoverChanged(item) }
        previews.$thumbnails
            .receive(on: RunLoop.main)
            .sink { [weak self] thumbs in
                MainActor.assumeIsolated { self?.previewsHost.isHidden = thumbs.isEmpty }
            }
            .store(in: &cancellables)
        previews.$appID
            .receive(on: RunLoop.main)
            .sink { [weak self] id in
                MainActor.assumeIsolated {
                    self?.strip.holdsShape = id != nil
                    if id == nil { self?.strip.cursorMoved(toScreen: NSEvent.mouseLocation) }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event)
            return event
        }
        // Lets the hide grace period expire when the cursor has stopped outside the dock.
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visible else { return }
                self.mouseMoved()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemDock.restore()
    }

    /// `kill`/`killall` skip applicationWillTerminate, so the normal Dock is restored on those signals too.
    private func restoreOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                SystemDock.restore()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func position() {
        let frame = screen.frame
        panel.setFrame(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.panelHeight), display: true)
        strip.frame = CGRect(x: 0, y: visible ? 0 : -60, width: frame.width, height: stripHeight)
        previewsHost.frame = CGRect(x: 0, y: Self.previewsBottom, width: frame.width, height: Self.panelHeight - Self.previewsBottom)
    }

    // MARK: Auto-hide

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation
        let frame = screen.frame

        if !visible {
            // Revealed by pushing against the bottom edge, like an auto-hiding Dock (not over full-screen apps).
            if mouse.y <= frame.minY + 1.5, frame.minX...frame.maxX ~= mouse.x, !frontmostIsFullScreen() {
                setVisible(true)
            }
            return
        }

        strip.cursorMoved(toScreen: mouse)

        let dock = strip.dockFrame
        // The bar, plus headroom above it for magnified icons and name tags.
        var active = CGRect(
            x: panel.frame.minX + dock.minX - 12,
            y: frame.minY,
            width: dock.width + 24,
            height: dock.maxY + model.largeSize - model.tileSize + 46
        )
        if !previews.thumbnails.isEmpty {
            let row = previews.rowRect
            let host = previewsHost.frame
            let onScreen = CGRect(
                x: panel.frame.minX + host.minX + row.minX,
                y: panel.frame.minY + host.maxY - row.maxY,
                width: row.width,
                height: row.height
            )
            active = active.union(onScreen.insetBy(dx: -12, dy: -12))
        }
        let inside = active.contains(mouse)
        panel.ignoresMouseEvents = !inside

        if inside {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.45 { setVisible(false) }
        } else {
            outsideSince = Date()
        }
    }

    private func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        outsideSince = nil
        panel.ignoresMouseEvents = !show
        model.setBadgePolling(show)
        if show {
            model.rebuild()
        } else {
            hoverWork?.cancel()
            previews.hide()
            strip.holdsShape = false
            strip.cursorLeft()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = show ? 0.32 : 0.26
            context.timingFunction = show
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                : CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.7, 0.4)
            context.allowsImplicitAnimation = true
            strip.animator().setFrameOrigin(CGPoint(x: 0, y: show ? 0 : -60))
            strip.animator().alphaValue = show ? 1 : 0
        }
    }

    // MARK: Previews

    private func hoverChanged(_ item: DockStrip.Item?) {
        hoverWork?.cancel()
        guard let app = item?.app, app.running else { return }
        if let center = strip.iconCenterOnScreen(app.id) {
            previews.anchorX = center.x - panel.frame.minX
        }
        previews.prepare(app)
        // Switching between icons while previews are already up is instant; the first one waits a moment.
        if previews.appID != nil {
            previews.show(for: app)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.strip.hovered == app.id else { return }
                self.previews.show(for: app)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func frontmostIsFullScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let size = screen.frame.size
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return bounds["Width"] == size.width && bounds["Height"] == size.height
        }
    }
}
