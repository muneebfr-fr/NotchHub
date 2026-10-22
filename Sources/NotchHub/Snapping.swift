import AppKit
import ApplicationServices
import Carbon
import SwiftUI

// MARK: - Zones

enum SnapZone: Equatable {
    case left(Double), right(Double)
    case top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize

    /// Target frame inside a screen's visible area, in AppKit (bottom-left origin) coordinates.
    func frame(in v: CGRect) -> CGRect {
        let halfW = v.width / 2, halfH = v.height / 2
        switch self {
        case .left(let f): return CGRect(x: v.minX, y: v.minY, width: v.width * f, height: v.height)
        case .right(let f): return CGRect(x: v.maxX - v.width * f, y: v.minY, width: v.width * f, height: v.height)
        case .top: return CGRect(x: v.minX, y: v.midY, width: v.width, height: halfH)
        case .bottom: return CGRect(x: v.minX, y: v.minY, width: v.width, height: halfH)
        case .topLeft: return CGRect(x: v.minX, y: v.midY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: v.midX, y: v.midY, width: halfW, height: halfH)
        case .bottomLeft: return CGRect(x: v.minX, y: v.minY, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: v.midX, y: v.minY, width: halfW, height: halfH)
        case .maximize: return v
        }
    }
}

// MARK: - Accessibility window access

private enum AXCoords {
    /// Accessibility uses a top-left origin anchored to the primary display.
    static var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAppKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

private struct AXWindow: @unchecked Sendable {
    let element: AXUIElement

    var position: CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    var size: CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// Position, then size, then position again: some apps clamp size against the old position.
    func setFrame(_ axRect: CGRect) {
        var origin = axRect.origin
        var size = axRect.size
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
    }

    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AXWindow(element: value as! AXUIElement)
    }

    /// The window under an Accessibility-space point, if any.
    static func at(_ axPoint: CGPoint) -> AXWindow? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit
        else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
        if role as? String == kAXWindowRole { return AXWindow(element: hit) }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return AXWindow(element: window as! AXUIElement)
    }
}

// MARK: - Animated moves

/// Glides a window to its target frame instead of jumping. Runs off the main thread so a slow app
/// can't stall the notch; starting a new move cancels the one in progress.
private enum WindowAnimator {
    private static let queue = DispatchQueue(label: "local.notchhub.window-animator", qos: .userInteractive)
    nonisolated(unsafe) private static var generation = 0

    static func animate(_ window: AXWindow, to target: CGRect, duration: Double = 0.28) {
        generation += 1
        let token = generation
        queue.async {
            guard let start = window.frame else {
                window.setFrame(target)
                return
            }
            let fps = 60.0
            let steps = max(1, Int(duration * fps))
            for step in 1...steps {
                guard token == generation else { return }
                let t = Double(step) / Double(steps)
                // Ease-out with a whisper of overshoot, so it settles rather than stopping dead.
                let eased = 1 - pow(1 - t, 3) + 0.06 * sin(t * .pi) * (1 - t)
                let frame = CGRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased
                )
                window.setFrame(step == steps ? target : frame)
                Thread.sleep(forTimeInterval: 1 / fps)
            }
        }
    }
}

// MARK: - Global hotkeys (Carbon; needs no extra permission)

private enum HotKeys {
    nonisolated(unsafe) static var actions: [UInt32: @MainActor () -> Void] = [:]
    nonisolated(unsafe) static var installed = false

    @MainActor
    static func register(keyCode: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let id = hotKeyID.id
                MainActor.assumeIsolated { HotKeys.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E484B59), id: id) // "NHKY"
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Drop-zone preview

@MainActor
private final class SnapPreview {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PreviewShape())
    }

    func show(_ frame: CGRect) {
        let target = frame.insetBy(dx: 6, dy: 6)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target.insetBy(dx: 30, dy: 30), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

private struct PreviewShape: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape
            .fill(Color.white.opacity(0.06))
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Snapper

/// Tiles windows by dragging them to a screen edge or corner, or with ⌃⌥ shortcuts.
@MainActor
final class WindowSnapper {
    private let preview = SnapPreview()

    private var dragWindow: AXWindow?
    private var dragStart: CGPoint?
    private var moving = false
    private var lastCheck = Date.distantPast
    private var pending: (zone: SnapZone, screen: NSScreen)?

    init() {
        installDragMonitors()
        installHotKeys()
    }

    // MARK: Drag to edge

    private func installDragMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                switch type {
                case .leftMouseDown: self?.mouseDown()
                case .leftMouseDragged: self?.mouseDragged()
                default: self?.mouseUp()
                }
            }
        }
    }

    private func mouseDown() {
        reset()
        guard AXIsProcessTrusted() else { return }
        let point = AXCoords.toAX(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard let window = AXWindow.at(point), window.pid != getpid() else { return }
        dragWindow = window
        dragStart = window.position
    }

    private func mouseDragged() {
        guard let window = dragWindow else { return }
        if !moving {
            // Only a window actually moving counts; dragging inside a window (selecting text, etc.) doesn't.
            let now = Date()
            guard now.timeIntervalSince(lastCheck) > 0.05 else { return }
            lastCheck = now
            guard let start = dragStart, let position = window.position,
                  abs(position.x - start.x) + abs(position.y - start.y) > 3
            else { return }
            moving = true
        }

        let mouse = NSEvent.mouseLocation
        guard let screen = AXCoords.screen(containing: mouse), let zone = Self.zone(for: mouse, on: screen.frame) else {
            pending = nil
            preview.hide()
            return
        }
        if pending?.zone != zone || pending?.screen != screen {
            pending = (zone, screen)
            preview.show(zone.frame(in: screen.visibleFrame))
        }
    }

    private func mouseUp() {
        if moving, let window = dragWindow, let pending {
            WindowAnimator.animate(window, to: AXCoords.toAX(pending.zone.frame(in: pending.screen.visibleFrame)))
        }
        reset()
    }

    private func reset() {
        dragWindow = nil
        dragStart = nil
        moving = false
        pending = nil
        preview.hide()
    }

    /// The cursor stops at the screen edge while dragging, so zones are a thin band along each edge.
    private static func zone(for p: CGPoint, on f: CGRect) -> SnapZone? {
        let edge: CGFloat = 3
        let corner: CGFloat = 80
        let atLeft = p.x <= f.minX + edge
        let atRight = p.x >= f.maxX - edge
        let atTop = p.y >= f.maxY - edge
        let atBottom = p.y <= f.minY + edge
        let nearTop = p.y >= f.maxY - corner
        let nearBottom = p.y <= f.minY + corner
        let nearLeft = p.x <= f.minX + corner
        let nearRight = p.x >= f.maxX - corner

        if (atLeft && nearTop) || (atTop && nearLeft) { return .topLeft }
        if (atRight && nearTop) || (atTop && nearRight) { return .topRight }
        if (atLeft && nearBottom) || (atBottom && nearLeft) { return .bottomLeft }
        if (atRight && nearBottom) || (atBottom && nearRight) { return .bottomRight }
        if atLeft { return .left(0.5) }
        if atRight { return .right(0.5) }
        if atTop { return .maximize }
        return nil
    }

    // MARK: Shortcut

    private var tapCount = 0
    private var tapWork: DispatchWorkItem?

    /// ⌃⌥T once: half, twice: third, three times: full screen. The side follows where the window already is.
    private func installHotKeys() {
        HotKeys.register(keyCode: kVK_ANSI_T, id: 1) { [weak self] in self?.tapped() }
    }

    private func tapped() {
        tapCount += 1
        tapWork?.cancel()
        // Wait briefly so a double or triple tap isn't applied as a single one first.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let count = min(self.tapCount, 3)
                self.tapCount = 0
                self.snapFocusedWindow(taps: count)
            }
        }
        tapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func snapFocusedWindow(taps: Int) {
        guard AXIsProcessTrusted(), let window = AXWindow.focused(),
              let position = window.position, let size = window.size
        else { return }
        let center = AXCoords.toAppKit(CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2))
        guard let screen = AXCoords.screen(containing: center) else { return }

        let onLeft = center.x < screen.visibleFrame.midX
        let zone: SnapZone = switch taps {
        case 1: onLeft ? .left(0.5) : .right(0.5)
        case 2: onLeft ? .left(1.0 / 3) : .right(1.0 / 3)
        default: .maximize
        }
        WindowAnimator.animate(window, to: AXCoords.toAX(zone.frame(in: screen.visibleFrame)))
    }
}
