import AppKit
import AudioToolbox
import CoreAudio
import OSLog
import SwiftUI

private let log = Logger(subsystem: "local.notchhub", category: "hud")

// MARK: - System volume (CoreAudio)

enum SystemAudio {
    static func outputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// False for outputs like HDMI that have no software volume; those keys are left to macOS.
    static var canSetVolume: Bool {
        guard let device = outputDevice() else { return false }
        var address = volumeAddress()
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func volume() -> Float? {
        guard let device = outputDevice() else { return nil }
        var address = volumeAddress()
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ value: Float) {
        guard let device = outputDevice() else { return }
        var address = volumeAddress()
        var v = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted() -> Bool {
        guard let device = outputDevice() else { return false }
        var address = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = outputDevice() else { return }
        var address = muteAddress()
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Built-in display brightness (private DisplayServices, loaded at runtime)

enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFunction: GetFunction? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setFunction: SetFunction? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }

    private static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let getFunction, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let setFunction, let display = builtInDisplay else { return }
        _ = setFunction(display, min(max(value, 0), 1))
    }
}

// MARK: - Media key interception

enum MediaKey {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h.
    init?(code: Int) {
        switch code {
        case 0: self = .volumeUp
        case 1: self = .volumeDown
        case 7: self = .mute
        case 2: self = .brightnessUp
        case 3: self = .brightnessDown
        default: return nil
        }
    }
}

private func mediaKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}

/// Swallows handled media keys so the native on-screen overlay never appears. Needs Accessibility permission.
@MainActor
final class MediaKeyTap {
    /// Return true if the key was handled and should be swallowed.
    var onKey: ((MediaKey, _ fineStep: Bool) -> Bool)?
    private(set) var isActive = false
    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var swallowedCodes: Set<Int> = []

    func start() {
        log.info("Accessibility trusted at launch: \(AXIsProcessTrusted(), privacy: .public)")
        if install() { return }
        // Each rebuild is a new app to macOS, so prompt once per build rather than once ever.
        let build = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { String($0.timeIntervalSince1970) } ?? "unknown"
        if UserDefaults.standard.string(forKey: "promptedBuild") != build {
            UserDefaults.standard.set(build, forKey: "promptedBuild")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        // Picks the permission up as soon as it's granted, without a relaunch.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if self?.install() == true { timer.invalidate() }
            }
        }
    }

    private func install() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Event tap creation failed despite Accessibility being trusted")
            return false
        }
        log.info("Media key tap installed")

        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        isActive = true
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("Event tap was disabled by the system (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else { return pass }

        let code = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA
        log.debug("System key code=\(code, privacy: .public) down=\(isDown, privacy: .public)")
        guard let key = MediaKey(code: code) else { return pass }

        if !isDown {
            return swallowedCodes.remove(code) != nil ? nil : pass
        }

        let flags = nsEvent.modifierFlags
        let fineStep = flags.contains(.shift) && flags.contains(.option)
        // Option alone opens Sound/Displays settings natively; leave that to macOS.
        if flags.contains(.option) && !fineStep { return pass }

        guard onKey?(key, fineStep) == true else {
            log.info("Key \(code, privacy: .public) not handled; passing to macOS")
            return pass
        }
        swallowedCodes.insert(code)
        return nil
    }
}

// MARK: - HUD state

@MainActor
final class HUDController: ObservableObject {
    enum Kind { case volume, brightness }

    @Published private(set) var kind: Kind = .volume
    @Published private(set) var level: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var visible = false

    private let tap = MediaKeyTap()
    private var hideWork: DispatchWorkItem?
    private var observedDevice: AudioDeviceID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastShownVolume: (Float, Bool)?

    init() {
        tap.onKey = { [weak self] key, fine in
            self?.handle(key, fineStep: fine) ?? false
        }
        tap.start()
        observeOutputDevice()
    }

    private func handle(_ key: MediaKey, fineStep: Bool) -> Bool {
        // Same step sizes as macOS: 16 notches, or 64 with Shift+Option.
        let step: Float = fineStep ? 1 / 64 : 1 / 16

        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard SystemAudio.canSetVolume, var volume = SystemAudio.volume() else { return false }
            var muted = SystemAudio.isMuted()
            switch key {
            case .mute:
                muted.toggle()
                SystemAudio.setMuted(muted)
            case .volumeUp:
                volume = Self.stepped(volume, by: step)
                if muted {
                    muted = false
                    SystemAudio.setMuted(false)
                }
                SystemAudio.setVolume(volume)
            default:
                volume = Self.stepped(volume, by: -step)
                SystemAudio.setVolume(volume)
            }
            lastShownVolume = (volume, muted)
            show(.volume, level: volume, muted: muted || volume == 0)

        case .brightnessUp, .brightnessDown:
            guard let current = DisplayBrightness.get() else { return false }
            let brightness = Self.stepped(current, by: key == .brightnessUp ? step : -step)
            DisplayBrightness.set(brightness)
            show(.brightness, level: brightness, muted: false)
        }
        return true
    }

    /// Snaps to the step grid first, so odd values (e.g. 0.53) land on a notch like the native control.
    private static func stepped(_ value: Float, by step: Float) -> Float {
        let notches = (value / abs(step)).rounded()
        return min(max((notches + (step > 0 ? 1 : -1)) * abs(step), 0), 1)
    }

    private func show(_ kind: Kind, level: Float, muted: Bool) {
        withAnimation(.smooth(duration: 0.2)) {
            self.kind = kind
            self.level = Double(level)
            self.muted = muted
        }
        if !visible {
            withAnimation(.spring(duration: 0.5, bounce: 0.28)) { visible = true }
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.spring(duration: 0.42, bounce: 0)) { self?.visible = false }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // Without Accessibility the keys can't be intercepted, so changes are picked up from CoreAudio instead.
    private func observeOutputDevice() {
        var defaultDevice = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindVolumeListener() }
        }
        bindVolumeListener()
    }

    private func bindVolumeListener() {
        if let device = observedDevice, let listener = deviceListener {
            var volume = SystemAudio.volumeAddress()
            var mute = SystemAudio.muteAddress()
            AudioObjectRemovePropertyListenerBlock(device, &volume, .main, listener)
            AudioObjectRemovePropertyListenerBlock(device, &mute, .main, listener)
        }
        guard let device = SystemAudio.outputDevice() else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.volumeChangedExternally() }
        }
        var volume = SystemAudio.volumeAddress()
        var mute = SystemAudio.muteAddress()
        AudioObjectAddPropertyListenerBlock(device, &volume, .main, listener)
        AudioObjectAddPropertyListenerBlock(device, &mute, .main, listener)
        observedDevice = device
        deviceListener = listener
    }

    private func volumeChangedExternally() {
        guard !tap.isActive, let volume = SystemAudio.volume() else { return }
        let muted = SystemAudio.isMuted()
        if let last = lastShownVolume, last.0 == volume, last.1 == muted { return }
        lastShownVolume = (volume, muted)
        show(.volume, level: volume, muted: muted || volume == 0)
    }
}

// MARK: - HUD view

struct HUDView: View {
    @EnvironmentObject var hud: HUDController

    private var symbol: String {
        switch hud.kind {
        case .volume: return hud.muted ? "speaker.slash.fill" : "speaker.wave.3.fill"
        case .brightness: return hud.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol, variableValue: hud.kind == .volume ? hud.level : nil)
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(Color.white.opacity(hud.muted ? 0.35 : 0.95))
                        .frame(width: max(6, geo.size.width * hud.level))
                }
            }
            .frame(height: 6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 236, height: 40)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Grows the HUD down out of the notch: it starts tucked up under the notch, narrow and transparent.
struct NotchSlide: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.45 + 0.55 * progress, y: 0.6 + 0.4 * progress, anchor: .top)
            .offset(y: (1 - progress) * -40)
            .opacity(progress)
    }
}
