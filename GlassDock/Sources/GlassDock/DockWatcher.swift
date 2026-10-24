import AppKit
import ApplicationServices

/// An icon in the real macOS Dock.
struct DockIcon: Equatable {
    let title: String
    let appPath: String?
    /// The icon's frame in AppKit screen coordinates (bottom-left origin), as currently drawn (magnified or not).
    let frame: CGRect
}

private func dockCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.selectionChanged() }
}

/// Follows the real Dock: the Dock reports which icon is under the cursor through Accessibility (its list's
/// "selected" child), so hover tracking is event-driven with no polling.
@MainActor
final class DockWatcher {
    /// Called with the hovered app icon, or nil when the cursor leaves the Dock's icons.
    var onHover: ((DockIcon?) -> Void)?

    private var observer: AXObserver?
    private var list: AXUIElement?
    private var dockPID: pid_t?
    private var retry: Timer?

    init() {
        attach()
        // The Dock restarts now and then (and after setting changes); re-attach when it does.
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    private func attach() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        if dock.processIdentifier == dockPID, list != nil { return }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = Self.children(app).first(where: { Self.string($0, kAXRoleAttribute) == kAXListRole }) else { return }
        var created: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, dockCallback, &created) == .success, let observer = created else { return }
        AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.observer = observer
        self.list = list
        dockPID = dock.processIdentifier
    }

    fileprivate func selectionChanged() {
        onHover?(hoveredIcon())
    }

    /// The app icon the Dock currently has highlighted under the cursor.
    func hoveredIcon() -> DockIcon? {
        guard let list else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXSelectedChildrenAttribute as CFString, &value) == .success,
              let item = (value as? [AXUIElement])?.first
        else { return nil }
        return icon(for: item)
    }

    /// Every app icon's current frame (used while a file is being dragged, when the Dock reports no hover).
    func appIcons() -> [DockIcon] {
        guard let list else { return [] }
        return Self.children(list).compactMap(icon(for:))
    }

    private func icon(for item: AXUIElement) -> DockIcon? {
        guard Self.string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
              let title = Self.string(item, kAXTitleAttribute),
              let frame = Self.frame(item)
        else { return nil }
        var url: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url)
        let path = (url as? URL).map { ((try? URL(resolvingAliasFileAt: $0)) ?? $0).resolvingSymlinksInPath().path }
        return DockIcon(title: title, appPath: path, frame: frame)
    }

    // MARK: Accessibility helpers

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success, let p,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success, let s
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        // Accessibility uses a top-left origin on the primary display.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: origin.x, y: primaryMaxY - origin.y - size.height, width: size.width, height: size.height)
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
