// Notch pet — parked for now, kept here to revive later.
//
// To revive: uncomment this file, then render `PetLayer()` inside NotchView's ZStack (after ExpandedView).
// That in-tree placement worked; hosting it in a separate strip-sized NSHostingView (the wiring commented
// out in App.swift) made it disappear. Its CPU cost while the panel is open was ~11-13%.

/*
import AppKit
import SwiftUI

/// The pet's own layer. It's hosted in a separate, strip-sized NSHostingView so the pet's animation
/// frames never trigger a layout pass of the main panel.
struct PetLayer: View {
    @EnvironmentObject var state: NotchState

    static let height: CGFloat = 44

    var body: some View {
        ZStack(alignment: .top) {
            if state.expanded {
                let panelWidth = NotchState.expandedSize.width
                let notchLeft = (panelWidth - state.notchSize.width) / 2
                let anchor = UnitPoint(x: notchLeft / panelWidth, y: 0.5)
                NotchPet(lane: 22...(notchLeft - 16), stripHeight: state.notchSize.height, panelWidth: panelWidth)
                    .frame(width: panelWidth, height: state.notchSize.height)
                    .transition(.asymmetric(
                        insertion: .modifier(active: PetWarp(progress: 0, anchor: anchor), identity: PetWarp(progress: 1, anchor: anchor))
                            .animation(.spring(duration: 0.55, bounce: 0.35).delay(0.25)),
                        removal: .modifier(active: PetWarp(progress: 0, anchor: anchor), identity: PetWarp(progress: 1, anchor: anchor))
                            .animation(.easeIn(duration: 0.2))
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A tiny creature that lives in the black strip beside the notch, only while the panel is open.
/// Closing the panel removes the view, which cancels its wander task and stops its timeline,
/// so it costs nothing while the notch is collapsed.
struct NotchPet: View {
    /// Horizontal range (in panel coordinates) the pet may wander, ending at the notch's edge.
    let lane: ClosedRange<CGFloat>
    let stripHeight: CGFloat
    let panelWidth: CGFloat

    @EnvironmentObject var music: MusicController

    @State private var x: CGFloat
    @State private var facingRight = false
    @State private var walking = false
    @State private var hopping = false
    @State private var pets = 0

    init(lane: ClosedRange<CGFloat>, stripHeight: CGFloat, panelWidth: CGFloat) {
        self.lane = lane
        self.stripHeight = stripHeight
        self.panelWidth = panelWidth
        // Starts right at the notch's edge, as if it just climbed out of it.
        _x = State(initialValue: lane.upperBound)
    }

    var body: some View {
        // Full frame rate only while moving; idling (blinks, gentle bob) looks the same at a fraction of the cost.
        let busy = walking || hopping || music.isPlaying
        TimelineView(.animation(minimumInterval: busy ? 1 / 30 : 1 / 12)) { context in
            PetBody(
                time: context.date.timeIntervalSinceReferenceDate,
                walking: walking,
                facingRight: facingRight,
                dancing: music.isPlaying,
                look: eyeOffset()
            )
            // Flattened into one GPU-rendered layer instead of a layer per shape.
            .drawingGroup()
        }
        .frame(width: 26, height: 24)
        .offset(y: hopping ? -7 : 0)
        .overlay(alignment: .top) { HeartPuff(trigger: pets) }
        .contentShape(Rectangle())
        .onTapGesture { petted() }
        .help("Hi!")
        .position(x: x, y: stripHeight / 2 + 1)
        .task { await wander() }
    }

    /// Eyes drift toward the cursor, at most a couple of points.
    private func eyeOffset() -> CGFloat {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return 0 }
        let petScreenX = screen.frame.midX + (x - panelWidth / 2)
        let dx = NSEvent.mouseLocation.x - petScreenX
        return max(-2.2, min(2.2, dx / 120))
    }

    private func wander() async {
        try? await Task.sleep(for: .milliseconds(500))
        while !Task.isCancelled {
            let roll = Double.random(in: 0..<1)
            if roll < 0.55 {
                let target = CGFloat.random(in: lane)
                let distance = abs(target - x)
                if distance > 14 {
                    facingRight = target > x
                    walking = true
                    let duration = Double(distance) / 42
                    withAnimation(.linear(duration: duration)) { x = target }
                    try? await Task.sleep(for: .seconds(duration))
                    walking = false
                }
            } else if roll < 0.7 {
                await hop()
            } else {
                facingRight.toggle()
            }
            try? await Task.sleep(for: .seconds(Double.random(in: 1.4...3.6)))
        }
    }

    private func hop() async {
        withAnimation(.spring(duration: 0.22, bounce: 0.4)) { hopping = true }
        try? await Task.sleep(for: .milliseconds(170))
        withAnimation(.spring(duration: 0.4, bounce: 0.55)) { hopping = false }
    }

    private func petted() {
        pets += 1
        Task { await hop() }
    }
}

private struct PetBody: View {
    let time: Double
    let walking: Bool
    let facingRight: Bool
    let dancing: Bool
    let look: CGFloat

    var body: some View {
        let stride = walking ? sin(time * 14) : 0
        let bob: Double = walking
            ? abs(sin(time * 14)) * 1.4
            : dancing ? abs(sin(time * 6.5)) * 2.6 : sin(time * 2) * 0.5
        let squash = 1 + (dancing ? 0.07 * sin(time * 13) : 0.025 * sin(time * 2))
        let blinking = time.truncatingRemainder(dividingBy: 4.3) < 0.13
        let face = look + (facingRight ? 1.2 : -1.2)

        ZStack {
            HStack(spacing: 6) {
                Capsule().frame(width: 5, height: 3).offset(y: stride > 0 ? -1.2 : 0)
                Capsule().frame(width: 5, height: 3).offset(y: stride < 0 ? -1.2 : 0)
            }
            .foregroundStyle(Color(red: 0.72, green: 0.78, blue: 0.9))
            .offset(y: 10)

            UnevenRoundedRectangle(
                topLeadingRadius: 11, bottomLeadingRadius: 7,
                bottomTrailingRadius: 7, topTrailingRadius: 11,
                style: .continuous
            )
            .fill(LinearGradient(
                colors: [.white, Color(red: 0.8, green: 0.87, blue: 0.98)],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 22, height: 19)
            .scaleEffect(x: 1 / squash, y: squash, anchor: .bottom)

            HStack(spacing: 5) {
                eye(blinking)
                eye(blinking)
            }
            .offset(x: face, y: -1.5)

            HStack(spacing: 11) {
                Circle().frame(width: 3.5, height: 3.5)
                Circle().frame(width: 3.5, height: 3.5)
            }
            .foregroundStyle(Color.pink.opacity(0.5))
            .offset(x: face * 0.6, y: 2.5)
        }
        .offset(y: -bob)
    }

    private func eye(_ blinking: Bool) -> some View {
        Capsule()
            .fill(Color(white: 0.1))
            .frame(width: 3, height: blinking ? 0.6 : 4.5)
    }
}

private struct HeartPuff: View {
    let trigger: Int

    private struct Frame {
        var opacity = 0.0
        var rise = 0.0
        var scale = 0.6
    }

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 8))
            .foregroundStyle(Color.pink)
            .keyframeAnimator(initialValue: Frame(), trigger: trigger) { content, frame in
                content
                    .opacity(frame.opacity)
                    .scaleEffect(frame.scale)
                    .offset(y: -frame.rise)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.35)
                    LinearKeyframe(0, duration: 0.35)
                }
                KeyframeTrack(\.rise) {
                    CubicKeyframe(16, duration: 0.78)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.1, duration: 0.3)
                    LinearKeyframe(0.9, duration: 0.48)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Grows the pet out of the notch's edge on open; on close, spins and sucks it back in.
struct PetWarp: ViewModifier {
    let progress: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.05 + 0.95 * progress, anchor: anchor)
            .rotationEffect(.degrees((1 - progress) * 220), anchor: anchor)
            .opacity(progress)
    }
}
*/
