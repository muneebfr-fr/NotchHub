import AppKit
import OSLog
import ServiceManagement
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        // Claude Code hooks invoke this binary; forward the event and exit without starting the app.
        if ClaudeHook.isInvocation {
            ClaudeHook.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class NotchState: ObservableObject {
    static let expandedSize = CGSize(width: 680, height: 250)
    /// Extra panel height when the app in front contributes a controls strip.
    static let contextStripHeight: CGFloat = 70
    /// Taller than the panel so cards that drop below the notch (e.g. a local add-on's answer card) have room.
    static let windowSize = CGSize(width: 680, height: 520)
    @Published var expanded = false
    @Published var glassOn = false
    @Published var notchSize = CGSize(width: 200, height: 32)
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    // private var petHost: NSView!  // Notch pet (parked, see NotchPet.swift)
    private let state = NotchState()
    private let clipboard = ClipboardStore()
    private let music = MusicController()
    private let hud = HUDController()
    private let recorder = ScreenRecorder()
    private let power = PowerMonitor()
    private let sensors = SensorMonitor()
    private let claudeCode = ClaudeCodeMonitor()
    private let appContext = AppContextMonitor()
    private let snapper = WindowSnapper()
    private let downloads = DownloadsTidier()
    private let mixer = VolumeMixer()
    private let visualizer = AudioVisualizer()
    private let glassDock = CompanionApp.glassDock()
    private let edgeShelf = CompanionApp.edgeShelf()
    private lazy var extensionHost = LocalExtensionHost(state: state)
    private var localExtension: LocalExtension?
    private var extensionIsInteractive = false
    private var appBeforeExtension: NSRunningApplication?
    private var hoverTimer: Timer?
    private var outsideSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerLoginItem()

        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        extensionHost.setInteractive = { [weak self] interactive in
            self?.setExtensionInteractive(interactive)
        }
        localExtension = LocalExtensions.load(host: extensionHost)

        panel.contentView = makeHost()

        // Notch pet (parked, see NotchPet.swift):
        // let petHost = NSHostingView(rootView: PetLayer().environmentObject(state).environmentObject(music))
        // petHost.sizingOptions = []
        // petHost.autoresizingMask = [.width, .minYMargin]
        // host.addSubview(petHost)
        // self.petHost = petHost

        positionPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }

        // Mouse-move monitors react instantly; global mouse (not keyboard) monitors need no Accessibility permission.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHover() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.checkHover() }
            return event
        }
        // Low-rate fallback so the close grace period still expires when the cursor stops moving.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHover() }
        }
    }

    /// While Mission Control (or App Exposé) is showing, the Dock adds an element identified "mc" to its
    /// accessibility tree. Only checked when the cursor is at the notch, so it costs nothing otherwise.
    private static func isMissionControlActive() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return false }
        for child in children {
            var identifier: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier)
            if identifier as? String == "mc" {
                Logger(subsystem: "local.notchhub", category: "hover").info("Mission Control is showing; not opening the panel")
                return true
            }
        }
        return false
    }

    private lazy var companions = CompanionApps(glassDock: glassDock, edgeShelf: edgeShelf)
    private lazy var clipboardActions = ClipboardActions(store: clipboard)

    /// The action pill's frame on screen.
    private var pillOnScreen: CGRect {
        let r = clipboardActions.pillRect
        return CGRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func makeHost() -> NSView {
        let host = NSHostingView(
            rootView: NotchView(localOverlay: localExtension?.overlay)
                .environmentObject(state)
                .environmentObject(clipboard)
                .environmentObject(music)
                .environmentObject(hud)
                .environmentObject(recorder)
                .environmentObject(power)
                .environmentObject(sensors)
                .environmentObject(claudeCode)
                .environmentObject(appContext)
                .environmentObject(downloads)
                .environmentObject(mixer)
                .environmentObject(visualizer)
                .environmentObject(companions)
                .environmentObject(clipboardActions)
        )
        // The window has a fixed size, so skip SwiftUI's per-layout window size negotiation.
        host.sizingOptions = []
        return host
    }

    // Re-registering every launch means quitting only stops the current session.
    private func registerLoginItem() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("NotchHub: login item registration failed: \(error)")
        }
    }

    private var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func positionPanel() {
        let screen = notchScreen
        state.notchSize = Self.notchSize(on: screen)
        let size = NotchState.windowSize
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        // petHost.frame = CGRect(x: 0, y: size.height - PetLayer.height, width: size.width, height: PetLayer.height)
    }

    private static func notchSize(on screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return CGSize(width: 200, height: 32) }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    private func checkHover() {
        // While an add-on has focus (e.g. a text field), hovering mustn't open the panel over it.
        guard !extensionIsInteractive else { return }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let notch = state.notchSize
        let notchRect = CGRect(
            x: frame.midX - notch.width / 2,
            y: frame.maxY - notch.height,
            width: notch.width,
            height: notch.height + 4
        ).insetBy(dx: -8, dy: 0)
        let expanded = CGSize(
            width: NotchState.expandedSize.width,
            height: NotchState.expandedSize.height
                + (appContext.hasStrip || downloads.hasLeftovers ? NotchState.contextStripHeight : 0)
        )
        let panelRect = CGRect(
            x: frame.midX - expanded.width / 2,
            y: frame.maxY - expanded.height,
            width: expanded.width,
            height: expanded.height + 4
        ).insetBy(dx: -16, dy: -16)

        // The clipboard action pill takes clicks only where it actually is.
        let overPill = clipboardActions.suggestion != nil && pillOnScreen.insetBy(dx: -6, dy: -6).contains(mouse)

        if !state.expanded {
            if !extensionIsInteractive { panel.ignoresMouseEvents = !overPill }
            // Mission Control's Spaces bar lives at the top of the screen; reaching for it mustn't open the panel.
            // A held button means something is being dragged (e.g. a window to the top edge), not a hover.
            if notchRect.contains(mouse), NSEvent.pressedMouseButtons == 0, !Self.isMissionControlActive() {
                setExpanded(true)
            }
            return
        }

        // A short grace period stops the panel flickering shut when the cursor grazes its edge.
        // Holding a mouse button (e.g. dragging an image out) keeps it open.
        if panelRect.contains(mouse) || overPill || NSEvent.pressedMouseButtons != 0 {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.18 { setExpanded(false) }
        } else {
            outsideSince = Date()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        outsideSince = nil
        guard expanded != state.expanded else { return }
        if expanded {
            // The browser's front tab may have changed since it was activated.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.appContext.refresh() }
            }
            // Resync after the open animation so the AppleScript call can't stall its first frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.music.refreshIfStale() }
            }
        }
        let animation: Animation = expanded
            ? .spring(duration: 0.55, bounce: 0.18)
            : .spring(duration: 0.38, bounce: 0)
        if expanded { state.glassOn = true }
        withAnimation(animation) {
            state.expanded = expanded
        }
        panel.ignoresMouseEvents = !expanded
        if !expanded {
            // Glass switches off only once the panel has finished shrinking into the (black) notch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.state.expanded else { return }
                    self.state.glassOn = false
                }
            }
        }
    }

    /// Gives an add-on clicks and keyboard focus without activating NotchHub, then hands focus back afterwards.
    private func setExtensionInteractive(_ interactive: Bool) {
        guard interactive != extensionIsInteractive else { return }
        extensionIsInteractive = interactive
        if interactive {
            appBeforeExtension = NSWorkspace.shared.frontmostApplication
            if state.expanded { setExpanded(false) }
            panel.ignoresMouseEvents = false
            panel.makeKey()
        } else {
            panel.ignoresMouseEvents = !state.expanded
            appBeforeExtension?.activate()
            appBeforeExtension = nil
        }
    }
}
