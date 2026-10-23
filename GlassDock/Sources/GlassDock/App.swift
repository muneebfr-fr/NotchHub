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
    private let extras = DockExtras()
    private let stack = StackState()
    private var shownForMissionControl = false
    private var visible = false
    private var outsideSince: Date?
    private var hoverWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellables: Set<AnyCancellable> = []

    // File-drag tracking for spring-loaded previews.
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var fileDragActive = false
    private var springAnchor: (id: CGWindowID, point: CGPoint, since: Date)?

    private static let panelHeight: CGFloat = 440
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
        strip = DockStrip(model: model, extras: extras)
        container.addSubview(strip)
        let host = NSHostingView(rootView: PreviewsView().environmentObject(previews).environmentObject(stack).environmentObject(extras))
        host.sizingOptions = []
        container.addSubview(host)
        previewsHost = host
        panel.contentView = container
        // Hidden views are skipped by layout passes, so the dock's frame updates never touch SwiftUI.
        host.isHidden = true
        position()
        panel.orderFrontRegardless()
        extras.refreshLoginItems()
        applyAccessibilityOptions()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAccessibilityOptions() }
        }

        strip.onHoverChange = { [weak self] item in self?.hoverChanged(item) }
        strip.onActivate = { [weak self] item in self?.activate(item) }
        strip.menuProvider = { [weak self] item in
            guard let self else { return nil }
            return DockMenu.make(for: item, model: self.model, extras: self.extras)
        }
        previews.onSpringLoaded = { [weak self] in self?.setVisible(false) }
        previews.$thumbnails.combineLatest(stack.$isOpen)
            .receive(on: RunLoop.main)
            .sink { [weak self] thumbs, open in
                MainActor.assumeIsolated { self?.previewsHost.isHidden = thumbs.isEmpty && !open }
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
        // A new drag session bumps the drag pasteboard's change count; a button release ends it.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .leftMouseDown { self.dragChangeCount = NSPasteboard(name: .drag).changeCount }
                if type == .leftMouseUp { self.endFileDrag() }
            }
        }
        // Mission Control shows the Dock; GlassDock follows it (a cheap Accessibility check a few times a second).
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMissionControl() }
        }
        // Lets the hide grace period expire when the cursor has stopped outside the dock.
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visible else { return }
                self.mouseMoved()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.endFileDrag() }
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
        strip.frame = CGRect(x: 0, y: visible ? 0 : hiddenY, width: frame.width, height: stripHeight)
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
        trackFileDrag(mouse)

        let dock = strip.dockFrame
        // The bar, plus headroom above it for magnified icons and name tags.
        var active = CGRect(
            x: panel.frame.minX + dock.minX - 12,
            y: frame.minY,
            width: dock.width + 24,
            height: dock.maxY + model.largeSize - model.tileSize + 46
        )
        if !previews.thumbnails.isEmpty || stack.isOpen {
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
        let inside = active.contains(mouse) || shownForMissionControl
        panel.ignoresMouseEvents = !inside

        if inside {
            outsideSince = nil
        } else if outsideSince == nil, !fileDragActive {
            // Leaving: previews close and the icons relax straight away; the dock itself slides off after a beat.
            hoverWork?.cancel()
            previews.hide()
            stack.isOpen = false
            strip.holdsShape = false
            strip.cursorLeft()
            outsideSince = Date()
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.45 { setVisible(false) }
        } else {
            outsideSince = Date()
        }
    }

    /// Fully below the screen when hidden, so it slides in from off-screen like the native Dock.
    private var hiddenY: CGFloat { -(stripHeight + 12) }

    private func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        outsideSince = nil
        panel.ignoresMouseEvents = !show
        model.setBadgePolling(show)
        if show {
            model.rebuild()
            extras.refreshMinimized()
        } else {
            hoverWork?.cancel()
            previews.hide()
            stack.isOpen = false
            strip.holdsShape = false
            strip.cursorLeft()
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            // Reduce Motion: a quick fade instead of a slide.
            strip.setFrameOrigin(CGPoint(x: 0, y: 0))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                strip.animator().alphaValue = show ? 1 : 0
            }
            return
        }
        strip.alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = show ? 0.3 : 0.32
            context.timingFunction = show
                ? CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.3, 1.0)
                : CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0)
            context.allowsImplicitAnimation = true
            strip.animator().setFrameOrigin(CGPoint(x: 0, y: show ? 0 : hiddenY))
        }
    }

    private func applyAccessibilityOptions() {
        strip.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !visible {
            strip.setFrameOrigin(CGPoint(x: 0, y: strip.reduceMotion ? 0 : hiddenY))
            strip.alphaValue = strip.reduceMotion ? 0 : 1
        }
    }

    private func checkMissionControl() {
        let active = Self.isMissionControlActive()
        if active, !visible {
            shownForMissionControl = true
            setVisible(true)
        } else if !active, shownForMissionControl {
            shownForMissionControl = false
            mouseMoved()
        }
    }

    private static func isMissionControlActive() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return false }
        return children.contains { child in
            var identifier: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier)
            return identifier as? String == "mc"
        }
    }

    // MARK: Stacks and minimised windows

    private func activate(_ item: DockStrip.Item) {
        switch item {
        case .downloads:
            if stack.isOpen {
                stack.isOpen = false
            } else {
                previews.hide()
                extras.refreshDownloads()
                if let frame = strip.iconFrameOnScreen("downloads") { stack.anchorX = frame.midX - panel.frame.minX }
                stack.isOpen = true
            }
        case .minimized(let window):
            extras.restore(window)
        default:
            break
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
        guard !previews.thumbnails.isEmpty else { return }

        // Mouse position in the previews overlay's top-left coordinates.
        let host = previewsHost.frame
        let local = CGPoint(x: mouse.x - panel.frame.minX - host.minX, y: panel.frame.minY + host.maxY - mouse.y)
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
        previews.dragMarker = nil
        previews.dragIcon = nil
    }

    // MARK: Previews

    private func hoverChanged(_ item: DockStrip.Item?) {
        hoverWork?.cancel()
        guard let app = item?.app, app.running, !stack.isOpen else { return }
        if let frame = strip.iconFrameOnScreen(app.id) {
            previews.anchorX = frame.midX - panel.frame.minX
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
