import AppKit
import ApplicationServices

/// The right-click menus, matching the native Dock's: window list, Options (Keep in Dock, Open at Login,
/// Show in Finder, desktop assignment), Hide and Quit (Force Quit with ⌥).
@MainActor
enum DockMenu {
    static func make(for item: DockStrip.Item, model: DockModel, extras: DockExtras) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch item {
        case .app(let app): appMenu(menu, app: app, model: model, extras: extras)
        case .downloads:
            menu.addItem(ClosureMenuItem(title: "Open in Finder") { NSWorkspace.shared.open(DockExtras.downloadsFolder) })
        case .trash:
            menu.addItem(ClosureMenuItem(title: "Open") { model.openTrash() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Empty Bin…") { emptyBin(model) })
        case .minimized(let window):
            menu.addItem(ClosureMenuItem(title: "Restore “\(window.title)”") { extras.restore(window) })
        case .separator:
            return nil
        }
        return menu
    }

    private static func appMenu(_ menu: NSMenu, app: DockApp, model: DockModel, extras: DockExtras) {
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.id }

        // Window list: ◆ marks minimised windows, ✓ the front one.
        if let running {
            let windows = windowList(running.processIdentifier)
            for (index, window) in windows.enumerated() {
                let title = window.minimized ? "◆ \(window.title)" : window.title
                let entry = ClosureMenuItem(title: title, state: index == 0 && !window.minimized && running.isActive ? .on : .off) {
                    if window.minimized {
                        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                    DockModel.bringForward(running)
                }
                menu.addItem(entry)
            }
            if !windows.isEmpty { menu.addItem(.separator()) }
        }

        let options = NSMenu()
        options.autoenablesItems = false
        options.addItem(ClosureMenuItem(title: "Keep in Dock", state: app.pinned ? .on : .off) { model.setPinned(app, !app.pinned) })
        let atLogin = extras.loginItemPaths.contains(app.url.path)
        options.addItem(ClosureMenuItem(title: "Open at Login", state: atLogin ? .on : .off) { extras.setOpenAtLogin(app, !atLogin) })
        options.addItem(ClosureMenuItem(title: "Show in Finder") { model.showInFinder(app) })
        options.addItem(.separator())
        let header = NSMenuItem(title: "Assign To", action: nil, keyEquivalent: "")
        header.isEnabled = false
        options.addItem(header)
        let current = extras.assignment(for: app)
        options.addItem(ClosureMenuItem(title: "All Desktops", state: current == .allDesktops ? .on : .off) { extras.assign(app, to: .allDesktops) })
        options.addItem(ClosureMenuItem(title: "This Desktop", state: current == .thisDesktop ? .on : .off) { extras.assign(app, to: .thisDesktop) })
        options.addItem(ClosureMenuItem(title: "None", state: current == .none ? .on : .off) { extras.assign(app, to: .none) })
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        menu.addItem(.separator())

        if let running {
            if !app.id.hasSuffix("Finder.app") {
                menu.addItem(ClosureMenuItem(title: running.isHidden ? "Show" : "Hide") {
                    if running.isHidden { running.unhide() } else { running.hide() }
                })
            }
            if !app.id.hasSuffix("Finder.app") {
                let force = NSEvent.modifierFlags.contains(.option)
                menu.addItem(ClosureMenuItem(title: force ? "Force Quit" : "Quit") {
                    if force { running.forceTerminate() } else { running.terminate() }
                })
            }
        } else {
            menu.addItem(ClosureMenuItem(title: "Open") { model.open(app) })
        }
    }

    private struct WindowEntry {
        let title: String
        let minimized: Bool
        let element: AXUIElement
    }

    private static func windowList(_ pid: pid_t) -> [WindowEntry] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?, minimized: CFTypeRef?, subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            guard let name = title as? String, !name.isEmpty, (subrole as? String) == kAXStandardWindowSubrole else { return nil }
            return WindowEntry(title: name, minimized: (minimized as? Bool) == true, element: window)
        }
    }

    /// Asks first, like Finder, because emptying the Bin can't be undone.
    private static func emptyBin(_ model: DockModel) {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Bin?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Empty Bin")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSAppleScript(source: #"tell application "Finder" to empty trash"#)?.executeAndReturnError(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.rebuild() }
    }
}
