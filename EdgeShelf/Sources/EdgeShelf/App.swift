import AppKit
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

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The shelf's container: an AppKit drop target (reliable for drags from any app) around the SwiftUI cards.
@MainActor
final class DropView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onTargeted: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff, NSPasteboard.PasteboardType("public.url")])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Cards dragged out of the shelf itself aren't re-added.
        guard sender.draggingSource == nil else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource == nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: ShelfPanel!
    private var container: DropView!
    private let store = ShelfStore()
    private let state = ShelfState()
    private var visible = false
    private var edgeSince: Date?
    private var outsideSince: Date?
    private var shelfCenterY: CGFloat = 0
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var cancellables: Set<AnyCancellable> = []

    private static let shelfWidth: CGFloat = 250
    private static let margin: CGFloat = 10
    private static var panelWidth: CGFloat { shelfWidth + margin * 2 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let root = NSView()
        root.wantsLayer = true
        container = DropView(frame: .zero)
        container.wantsLayer = true
        let host = NSHostingView(rootView: ShelfView().environmentObject(store).environmentObject(state))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        root.addSubview(container)
        panel.contentView = root
        container.alphaValue = 0

        container.onDrop = { [weak self] pasteboard in self?.store.add(from: pasteboard) ?? false }
        container.onTargeted = { [weak self] on in self?.state.dropTargeted = on }

        // The shelf grows and shrinks with its contents.
        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutShelf(animated: true) }
            }
            .store(in: &cancellables)

        place(on: NSScreen.main ?? NSScreen.screens[0])
        panel.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event)
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragChangeCount = NSPasteboard(name: .drag).changeCount }
        }
        // Lets dwell and hide timers expire while the cursor rests.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visible || self.edgeSince != nil else { return }
                self.mouseMoved()
            }
        }
    }

    // MARK: Geometry

    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]

    private func place(on screen: NSScreen) {
        self.screen = screen
        let f = screen.frame
        panel.setFrame(CGRect(x: f.maxX - Self.panelWidth, y: f.minY, width: Self.panelWidth, height: f.height), display: true)
        layoutShelf(animated: false)
    }

    private var shelfHeight: CGFloat {
        let content = store.items.isEmpty ? 150 : 46 + CGFloat(store.items.count) * 50 + 16
        return min(max(content, 150), screen.visibleFrame.height * 0.7)
    }

    private func shelfFrame(shown: Bool) -> CGRect {
        let height = shelfHeight
        let visibleFrame = screen.visibleFrame
        let minY = visibleFrame.minY - screen.frame.minY + 8
        let maxY = visibleFrame.maxY - screen.frame.minY - height - 8
        let y = min(max(shelfCenterY - height / 2, minY), max(minY, maxY))
        // Hidden, it waits just past the screen edge so it slides in from the side.
        let x = shown ? Self.margin : Self.panelWidth + 20
        return CGRect(x: x, y: y, width: Self.shelfWidth, height: height)
    }

    private func layoutShelf(animated: Bool) {
        let frame = shelfFrame(shown: visible)
        guard animated else {
            container.frame = frame
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            context.allowsImplicitAnimation = true
            container.animator().frame = frame
        }
    }

    // MARK: Reveal and hide

    private var isDraggingSomething: Bool {
        NSEvent.pressedMouseButtons & 1 == 1 && NSPasteboard(name: .drag).changeCount != dragChangeCount
    }

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation

        if !visible {
            guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) }),
                  mouse.x >= screen.frame.maxX - 1.5
            else {
                edgeSince = nil
                return
            }
            // Something being dragged reveals it at once; a plain cursor has to rest briefly, so scrolling
            // or reaching for a window edge doesn't trigger it.
            if isDraggingSomething {
                show(on: screen, at: mouse.y)
            } else if let since = edgeSince {
                if Date().timeIntervalSince(since) > 0.22 { show(on: screen, at: mouse.y) }
            } else {
                edgeSince = Date()
            }
            return
        }

        let shelf = container.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let active = shelf.insetBy(dx: -18, dy: -18)
            .union(CGRect(x: screen.frame.maxX - 4, y: shelf.minY - 18, width: 4, height: shelf.height + 36))
        let inside = active.contains(mouse)
        panel.ignoresMouseEvents = !inside

        if inside {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.4 { hide() }
        } else {
            outsideSince = Date()
        }
    }

    private func show(on screen: NSScreen, at y: CGFloat) {
        edgeSince = nil
        outsideSince = nil
        if screen != self.screen { place(on: screen) }
        shelfCenterY = y - screen.frame.minY
        container.frame = shelfFrame(shown: false)
        visible = true
        panel.ignoresMouseEvents = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            context.allowsImplicitAnimation = true
            container.animator().frame = shelfFrame(shown: true)
            container.animator().alphaValue = 1
        }
    }

    private func hide() {
        visible = false
        outsideSince = nil
        panel.ignoresMouseEvents = true
        state.dropTargeted = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.7, 0.4)
            context.allowsImplicitAnimation = true
            container.animator().frame = shelfFrame(shown: false)
            container.animator().alphaValue = 0
        }
    }
}
