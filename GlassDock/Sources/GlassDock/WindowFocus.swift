import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "local.glassdock", category: "focus")

/// Focuses one exact window, even on another desktop.
///
/// Apps only expose the windows on the current desktop to Accessibility, and macOS won't switch desktops for an
/// activation requested by a background app. So for a window elsewhere this slides to its desktop with the same
/// "Move left/right a space" shortcut macOS uses (native animation), waits until the window is on screen and
/// visible to Accessibility, then raises it.
@MainActor
enum WindowFocus {
    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let axGetWindow: GetWindowID? = appServices.flatMap { dlsym($0, "_AXUIElementGetWindow") }.map { unsafeBitCast($0, to: GetWindowID.self) }
    private static let mainConnection: MainConnection? = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }.map { unsafeBitCast($0, to: MainConnection.self) }
    private static let spacesForWindows: SpacesForWindows? = skyLight.flatMap { dlsym($0, "SLSCopySpacesForWindows") }.map { unsafeBitCast($0, to: SpacesForWindows.self) }
    private static let managedSpaces: ManagedSpaces? = skyLight.flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") }.map { unsafeBitCast($0, to: ManagedSpaces.self) }

    static func focus(windowID: CGWindowID, pid: pid_t, title: String) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if isOnScreen(windowID) {
            raise(pid: pid, windowID: windowID, title: title, app: app)
            return
        }
        guard let steps = desktopSteps(to: windowID), steps != 0, moveShortcutsEnabled else {
            log.info("focus: can't route to window's desktop; activating app")
            WindowFocus.bringForward(app)
            return
        }
        log.info("focus: moving \(steps, privacy: .public) desktop(s)")
        postDesktopMoves(steps)
        waitForWindow(windowID, pid: pid, title: title, app: app, deadline: Date().addingTimeInterval(2.5))
    }

    // MARK: Raising

    /// macOS ignores activation requests from background apps, so this goes through Accessibility, which
    /// activates the app and switches to the desktop of its most recent window.
    static func bringForward(_ app: NSRunningApplication, raiseMain: Bool = true) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var window: CFTypeRef?
        // When a specific window was just raised, don't raise the app's main window over it.
        if raiseMain, AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &window) == .success, let window {
            AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
        }
        app.activate(options: [.activateAllWindows])
    }

    private static func raise(pid: pid_t, windowID: CGWindowID, title: String, app: NSRunningApplication) {
        if let window = axWindow(pid: pid, windowID: windowID, title: title) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        WindowFocus.bringForward(app, raiseMain: false)
    }

    /// After a desktop slide: polls until the window is on screen and Accessibility can see it (the app only
    /// reports it once the slide has finished), then raises it.
    private static func waitForWindow(_ windowID: CGWindowID, pid: pid_t, title: String, app: NSRunningApplication, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            if isOnScreen(windowID), axWindow(pid: pid, windowID: windowID, title: title) != nil {
                raise(pid: pid, windowID: windowID, title: title, app: app)
            } else if Date() < deadline {
                waitForWindow(windowID, pid: pid, title: title, app: app, deadline: deadline)
            } else {
                log.info("focus: window didn't appear in time; activating app")
                WindowFocus.bringForward(app)
            }
        }
    }

    private static func axWindow(pid: pid_t, windowID: CGWindowID, title: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first { window in
            var id: CGWindowID = 0
            return axGetWindow?(window, &id) == .success && id == windowID
        } ?? windows.first { window in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
            return !title.isEmpty && (t as? String) == title
        }
    }

    private static func isOnScreen(_ windowID: CGWindowID) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    // MARK: Desktops

    /// How many desktops right (positive) or left (negative) the window's desktop is from the current one,
    /// on the same display, in Mission Control order.
    private static func desktopSteps(to windowID: CGWindowID) -> Int? {
        guard let mainConnection, let spacesForWindows, let managedSpaces else { return nil }
        let connection = mainConnection()
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let windowSpace = (spacesForWindows(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber])?.first?.uint64Value,
              let displays = managedSpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for display in displays {
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            guard let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let from = spaces.firstIndex(of: current), let to = spaces.firstIndex(of: windowSpace)
            else { continue }
            return to - from
        }
        return nil
    }

    /// The "Move left/right a space" shortcuts (⌃← / ⌃→) must be on, as they are by default.
    private static var moveShortcutsEnabled: Bool {
        guard let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        else { return true }
        for key in ["79", "81"] {
            if let entry = hotkeys[key] as? [String: Any], (entry["enabled"] as? Bool) == false { return false }
        }
        return true
    }

    private static func postDesktopMoves(_ steps: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let key: CGKeyCode = steps > 0 ? 124 : 123
        // Arrow keys carry the function and keypad flags when typed on a real keyboard.
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        for _ in 0..<abs(steps) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { return }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
