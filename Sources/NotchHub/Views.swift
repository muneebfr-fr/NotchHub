import AppKit
import SwiftUI

private enum Palette {
    static let deep = Color(white: 0.04)
    static let navy = Color(white: 0.14)
    static let sky = Color(red: 0.80, green: 0.86, blue: 0.94)
    static let ice = Color(white: 0.94)
    static let primary = Color.white.opacity(0.95)
    static let secondary = ice.opacity(0.62)
    static let tertiary = ice.opacity(0.42)
    static let hover = Color.white.opacity(0.12)
}

// MARK: - Notch container

struct NotchView: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var music: MusicController
    @EnvironmentObject var hud: HUDController
    @EnvironmentObject var recorder: ScreenRecorder

    private let liveActivityWing: CGFloat = 34

    private var showsRecording: Bool {
        !state.expanded && recorder.isRecording
    }

    private var showsLiveActivity: Bool {
        !state.expanded && (music.isPlaying || recorder.isRecording)
    }

    private var size: CGSize {
        if state.expanded { return NotchState.expandedSize }
        let wings = showsLiveActivity ? liveActivityWing * 2 : 0
        return CGSize(width: state.notchSize.width + wings, height: state.notchSize.height)
    }

    var body: some View {
        let radius: CGFloat = state.expanded ? 32 : 12
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)

        ZStack(alignment: .top) {
            NotchSurface(expanded: state.expanded, notchHeight: state.notchSize.height, shape: shape)
                .frame(width: size.width, height: size.height)

            if state.expanded {
                ExpandedView()
                    .padding(.top, state.notchSize.height + 8)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: SoftReveal(progress: 0),
                            identity: SoftReveal(progress: 1)
                        ).animation(.spring(duration: 0.5, bounce: 0.1).delay(0.08)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            } else if showsRecording {
                // Recording takes priority over music so it's always obvious the screen is being captured.
                HStack {
                    RecordingDot()
                    Spacer()
                    RecordingTimer()
                }
                .padding(.horizontal, 9)
                .frame(width: size.width, height: state.notchSize.height)
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if showsLiveActivity {
                HStack {
                    ArtworkView(image: music.artwork, size: 20, radius: 5)
                    Spacer()
                    EqualizerView()
                }
                .padding(.horizontal, 9)
                .frame(width: size.width, height: state.notchSize.height)
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            if hud.visible && !state.expanded {
                HUDView()
                    .padding(.top, state.notchSize.height + 8)
                    .transition(.modifier(
                        active: NotchSlide(progress: 0),
                        identity: NotchSlide(progress: 1)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.primary)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.45, bounce: 0.15), value: showsLiveActivity)
    }
}

struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .frame(width: 20)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct RecordingTimer: View {
    @EnvironmentObject var recorder: ScreenRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsed(since: recorder.phase, now: context.date))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.red.opacity(0.95))
        }
    }

    static func elapsed(since phase: ScreenRecorder.Phase, now: Date) -> String {
        guard case .recording(let start) = phase else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Fade and gently drop content into place as the panel opens. Only GPU-cheap properties are animated.
struct SoftReveal: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.94 + 0.06 * progress, anchor: .top)
            .offset(y: (1 - progress) * -8)
    }
}

/// Black while collapsed so it matches the physical notch; native Liquid Glass once open.
struct NotchSurface: View {
    let expanded: Bool
    let notchHeight: CGFloat
    let shape: UnevenRoundedRectangle

    var body: some View {
        shape
            .fill(Color.black.opacity(expanded ? 0 : 1))
            .overlay(alignment: .top) {
                // Keeps the strip around the physical notch black so the glass appears to flow out of it.
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.45),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: notchHeight * 1.9)
                .opacity(expanded ? 1 : 0)
            }
            .clipShape(shape)
            .glassEffect(expanded ? .regular : .identity, in: shape)
    }
}

// MARK: - Layout

struct ExpandedView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NowPlayingCard().frame(width: 272)
            ClipboardCard().frame(maxWidth: .infinity)
            ShortcutsCard().frame(width: 136)
        }
    }
}

struct GlassCard<Content: View>: View {
    let title: String
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Palette.tertiary)
                Spacer()
                accessory
            }
            .frame(height: 14)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color.white.opacity(0.05)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    var idle: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, radius: radius, idle: idle)
    }

    private struct HoverButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        let idle: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(hovering ? Palette.hover : idle)
                )
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Music

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var gloss = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Palette.navy, Palette.deep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Palette.sky.opacity(0.7))
            }
            if gloss {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.22), location: 0),
                        .init(color: .clear, location: 0.5),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(gloss ? shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75) : nil)
    }
}

struct EqualizerView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (3.2 + Double(i) * 0.9) + Double(i) * 1.7
                    Capsule()
                        .frame(width: 2.5, height: 4 + 9 * (0.5 + 0.5 * sin(phase)))
                }
            }
            .frame(width: 20, height: 14)
            .foregroundStyle(Palette.sky)
        }
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject var music: MusicController

    var body: some View {
        GlassCard(title: music.player.map { "Now Playing · \($0)" } ?? "Now Playing") {
            HStack(spacing: 14) {
                ArtworkView(image: music.artwork, size: 66, radius: 12, gloss: true)
                    .background {
                        if let glow = music.artworkGlow {
                            RadialGradient(colors: [glow.opacity(0.55), .clear], center: .center, startRadius: 10, endRadius: 58)
                                .frame(width: 116, height: 116)
                                .allowsHitTesting(false)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.player == nil ? "Nothing playing" : music.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(music.player == nil ? Palette.secondary : Palette.primary)
                        .lineLimit(2)
                    if music.player != nil {
                        Text(music.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: music.title)
            }
            Spacer(minLength: 0)
            if music.player != nil {
                ProgressBar()
                HStack(spacing: 18) {
                    controlButton("backward.fill", size: 13) { music.previous() }
                    playButton
                    controlButton("forward.fill", size: 13) { music.next() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var playButton: some View {
        Button { music.playPause() } label: {
            Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.ice.opacity(0.85))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }
}

struct ProgressBar: View {
    @EnvironmentObject var music: MusicController

    var body: some View {
        // The bar moves under 1px per second, so a 1s tick needs no animation.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = music.currentPosition(at: context.date)
            let fraction = music.duration > 0 ? position / music.duration : 0
            HStack(spacing: 8) {
                Text(Self.format(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: [Palette.sky, Palette.ice], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
                Text(Self.format(music.duration))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Palette.tertiary)
        }
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Clipboard

struct ClipboardCard: View {
    enum Tab { case text, images }

    @EnvironmentObject var clipboard: ClipboardStore
    @State private var tab: Tab = .text
    @State private var lastCopied: String?
    @State private var lastCopiedImage: UUID?
    @Namespace private var tabSelection

    var body: some View {
        GlassCard(title: "", accessory: AnyView(header)) {
            switch tab {
            case .text: textList
            case .images: imageGrid
            }
        }
        // Jump to whichever kind was copied most recently.
        .onChange(of: clipboard.items.first) {
            if clipboard.lastAddedKind == .text { selectTab(.text) }
        }
        .onChange(of: clipboard.images.first?.id) {
            if clipboard.lastAddedKind == .image { selectTab(.images) }
        }
    }

    private func selectTab(_ newTab: Tab) {
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { tab = newTab }
    }

    private var header: some View {
        HStack(spacing: 2) {
            tabButton("Text", .text)
            tabButton("Images", .images)
            Spacer(minLength: 0)
            if tab == .text ? !clipboard.items.isEmpty : !clipboard.images.isEmpty {
                Button("Clear") {
                    if tab == .text {
                        clipboard.clearText()
                        lastCopied = nil
                    } else {
                        clipboard.clearImages()
                        lastCopiedImage = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { selectTab(value) } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tab == value ? Palette.primary : Palette.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background {
                    if tab == value {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: tabSelection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Palette.sky.opacity(0.7))
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let fadeMask = LinearGradient(
        stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom
    )

    @ViewBuilder private var textList: some View {
        if clipboard.items.isEmpty {
            emptyState("doc.on.clipboard", "Copied text shows up here")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(clipboard.items, id: \.self) { item in
                        clipboardRow(item)
                    }
                }
            }
            .scrollIndicators(.never)
            .mask(Self.fadeMask)
        }
    }

    @ViewBuilder private var imageGrid: some View {
        if clipboard.images.isEmpty {
            emptyState("photo.on.rectangle", "Copied images and screenshots show up here")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], spacing: 6) {
                    ForEach(clipboard.images) { image in
                        imageTile(image)
                    }
                }
            }
            .scrollIndicators(.never)
            .mask(Self.fadeMask)
        }
    }

    private func imageTile(_ image: ClipImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let copied = lastCopiedImage == image.id

        return Button {
            clipboard.copy(image)
            lastCopiedImage = image.id
        } label: {
            Color.clear
                .frame(height: 54)
                .frame(maxWidth: .infinity)
                .overlay {
                    Image(nsImage: image.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(copied ? 0.7 : 0.12), lineWidth: copied ? 1.5 : 0.5))
                .overlay(alignment: .topTrailing) {
                    if copied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, Color.black.opacity(0.45))
                            .padding(4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onDrag { Self.dragProvider(for: image) }
        .help("Click to copy, or drag it into another app")
        .animation(.spring(duration: 0.3, bounce: 0.3), value: copied)
    }

    /// Drags a real PNG file so it drops cleanly into Finder, chat apps and email.
    private static func dragProvider(for image: ClipImage) -> NSItemProvider {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Image \(image.id.uuidString.prefix(8)).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let png = image.type == .png
                ? image.data
                : NSBitmapImageRep(data: image.data)?.representation(using: .png, properties: [:])
            try? png?.write(to: url)
        }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func clipboardRow(_ item: String) -> some View {
        Button {
            clipboard.copy(item)
            lastCopied = item
        } label: {
            HStack(spacing: 8) {
                Text(item.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(Palette.primary.opacity(0.88))
                Spacer(minLength: 0)
                if lastCopied == item {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.sky)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 8))
        .animation(.spring(duration: 0.3, bounce: 0.3), value: lastCopied)
    }
}

// MARK: - Shortcuts

struct ShortcutsCard: View {
    var body: some View {
        GlassCard(
            title: "Shortcuts",
            accessory: AnyView(
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(radius: 5))
                .foregroundStyle(Palette.tertiary)
                .help("Quit NotchHub (starts again at next login)")
            )
        ) {
            GlassEffectContainer(spacing: 5) {
                VStack(spacing: 5) {
                    ForEach(QuickLinks.all) { link in
                    shortcut(link.name, symbol: link.symbol) { NSWorkspace.shared.open(link.url) }
                }
                    shortcut("Claude", symbol: "sparkles") { ClaudeShortcuts.openApp() }
                    RecordButton()
                }
            }
        }
    }

    private func shortcut(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.sky)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(4)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct RecordButton: View {
    @EnvironmentObject var recorder: ScreenRecorder

    private var label: (title: String, symbol: String, tint: Color) {
        switch recorder.phase {
        case .idle: return ("Record", "record.circle", Palette.sky)
        case .starting: return ("Starting…", "record.circle", Palette.tertiary)
        case .recording: return ("Stop", "stop.circle.fill", .red)
        case .saved: return ("Show file", "checkmark.circle.fill", .green)
        case .failed(let message): return (message, "exclamationmark.triangle.fill", .orange)
        }
    }

    var body: some View {
        let label = label

        Button { recorder.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: label.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(label.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
                Text(label.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if recorder.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(RecordingTimer.elapsed(since: recorder.phase, now: context.date))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                    }
                }
            }
            .padding(4)
            .contentShape(Rectangle())
            .glassEffect(
                recorder.isRecording ? .regular.tint(.red.opacity(0.35)).interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(recorder.isRecording ? "Stop recording" : "Record the screen with system audio to ~/Movies/NotchHub")
        .animation(.spring(duration: 0.3, bounce: 0.2), value: recorder.phase)
    }
}
