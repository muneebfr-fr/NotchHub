import AppKit
import Carbon
import ScreenCaptureKit
import SwiftUI

struct SwitcherWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let appIcon: NSImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title }
}

/// ⌥Tab: a window switcher with live thumbnails for every window on every desktop. ⌘Tab is left untouched.
/// Hold ⌥ and tap Tab (⇧Tab goes back); releasing ⌥ jumps to the chosen window.
@MainActor
final class Switcher: ObservableObject {
    @Published private(set) var windows: [SwitcherWindow] = []
    @Published var selected = 0
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var visible = false

    private var panel: NSPanel!
    private var active = false
    private var showWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    /// Most recently activated apps first, so windows on other desktops can be ordered by recency too.
    private var appOrder: [pid_t] = []
    /// Hover only selects once the mouse has actually moved since the panel opened.
    private var mouseAtShow: CGPoint = .zero
    var mouseHasMoved: Bool { hypot(NSEvent.mouseLocation.x - mouseAtShow.x, NSEvent.mouseLocation.y - mouseAtShow.y) > 3 }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SwitcherView().environmentObject(self))
        host.sizingOptions = []
        panel.contentView = host

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.appOrder.removeAll { $0 == pid }
                self.appOrder.insert(pid, at: 0)
            }
        }

        SwitcherHotKeys.install { [weak self] backwards in self?.tab(backwards: backwards) }
        // Releasing ⌥ commits; Esc (while ⌥ is held) cancels.
        let flags: (NSEvent) -> Void = { [weak self] event in
            let option = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { if !option { self?.commit() } }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flags(event)
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let escape = event.keyCode == UInt16(kVK_Escape)
            MainActor.assumeIsolated { if escape { self?.cancel() } }
        }
    }

    // MARK: Keyboard

    private func tab(backwards: Bool) {
        if !active {
            active = true
            windows = Self.listWindows(appOrder: appOrder)
            guard !windows.isEmpty else { active = false; return }
            // Like ⌘Tab: the first press already points at the previous window.
            selected = windows.count > 1 ? (backwards ? windows.count - 1 : 1) : 0
            captureThumbnails()
            // Only appears if ⌥ is still held a beat later, so a quick ⌥Tab just flips windows with no flash.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.show() }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
            return
        }
        guard !windows.isEmpty else { return }
        selected = (selected + (backwards ? -1 : 1) + windows.count) % windows.count
        if !visible { show() }
    }

    private func show() {
        guard active, !visible else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        panel.setFrame(screen.visibleFrame, display: false)
        mouseAtShow = NSEvent.mouseLocation
        panel.orderFrontRegardless()
        withAnimation(.spring(duration: 0.28, bounce: 0.12)) { visible = true }
    }

    func commit() {
        guard active else { return }
        let choice = windows.indices.contains(selected) ? windows[selected] : nil
        close()
        if let choice { WindowFocus.focus(windowID: choice.id, pid: choice.pid, title: choice.title) }
    }

    /// Clicking a card.
    func choose(_ index: Int) {
        selected = index
        commit()
    }

    private func cancel() {
        guard active else { return }
        close()
    }

    private func close() {
        active = false
        showWork?.cancel()
        captureTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.active else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: Windows

    /// Current desktop's windows front to back, then other desktops' windows by how recently their app was used.
    private static func listWindows(appOrder: [pid_t]) -> [SwitcherWindow] {
        let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { ($0.processIdentifier, $0) })
        let onScreenIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var candidates: [(SwitcherWindow, Int)] = []
        for info in all {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = running[pid],
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 150, (bounds["Height"] ?? 0) > 100,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0
            else { continue }
            let onScreenRank = onScreenIDs.firstIndex(of: id)
            // Off-screen windows count only if they're really on some desktop.
            if onScreenRank == nil, !WindowFocus.isOnSomeDesktop(id) { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let window = SwitcherWindow(
                id: id, pid: pid, title: title.isEmpty ? (app.localizedName ?? "Window") : title,
                appName: app.localizedName ?? "", appIcon: app.icon ?? NSImage()
            )
            let rank = onScreenRank ?? (10_000 + (appOrder.firstIndex(of: pid) ?? 5_000))
            candidates.append((window, rank))
        }
        return candidates.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Thumbnails arrive as they're captured; cards show the app icon until then.
    private func captureThumbnails() {
        captureTask?.cancel()
        let ids = Set(windows.map(\.id))
        captureTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                for window in targets.prefix(24) {
                    group.addTask {
                        let config = SCStreamConfiguration()
                        let scale = min(1, 220 / max(window.frame.width, 1))
                        config.width = Int(window.frame.width * scale * 2)
                        config.height = Int(window.frame.height * scale * 2)
                        config.showsCursor = false
                        guard let image = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
                        ) else { return (window.windowID, nil) }
                        return (window.windowID, NSImage(cgImage: image, size: NSSize(width: window.frame.width * scale, height: window.frame.height * scale)))
                    }
                }
                for await (id, image) in group {
                    guard !Task.isCancelled, let image, let self else { continue }
                    self.thumbnails[id] = image
                }
            }
        }
    }
}

// MARK: - Hotkeys (Carbon: system-wide, needs no extra permission)

private enum SwitcherHotKeys {
    nonisolated(unsafe) static var handler: (@MainActor (Bool) -> Void)?

    @MainActor
    static func install(_ handler: @escaping @MainActor (Bool) -> Void) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let backwards = hotKeyID.id == 2
            MainActor.assumeIsolated { SwitcherHotKeys.handler?(backwards) }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), EventHotKeyID(signature: OSType(0x47445357), id: 1), GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey | shiftKey), EventHotKeyID(signature: OSType(0x47445357), id: 2), GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - View

struct SwitcherView: View {
    @EnvironmentObject var switcher: Switcher

    var body: some View {
        GeometryReader { geo in
            let columns = max(1, min(switcher.windows.count, Int((geo.size.width - 80) / 232), 6))
            Group {
                if switcher.visible {
                    GlassEffectContainer(spacing: 12) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 12), count: columns), spacing: 12) {
                            ForEach(Array(switcher.windows.enumerated()), id: \.element.id) { index, window in
                                SwitcherCard(window: window, index: index)
                            }
                        }
                        .padding(16)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct SwitcherCard: View {
    @EnvironmentObject var switcher: Switcher
    let window: SwitcherWindow
    let index: Int

    var body: some View {
        let selected = switcher.selected == index
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                if let thumb = switcher.thumbnails[window.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity)
                } else {
                    Image(nsImage: window.appIcon).resizable().frame(width: 48, height: 48).opacity(0.85)
                }
            }
            .frame(width: 204, height: 124)
            HStack(spacing: 6) {
                Image(nsImage: window.appIcon).resizable().frame(width: 18, height: 18)
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 204, alignment: .leading)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.16 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 2)
        }
        .scaleEffect(selected ? 1.03 : 1)
        .animation(.spring(duration: 0.2, bounce: 0.2), value: selected)
        .animation(.easeOut(duration: 0.2), value: switcher.thumbnails[window.id] != nil)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { if $0, switcher.mouseHasMoved { switcher.selected = index } }
        .onTapGesture { switcher.choose(index) }
        .help(window.appName)
    }
}
