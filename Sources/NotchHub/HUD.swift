import AppKit
import AudioToolbox
import Carbon
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
    enum Kind: Equatable {
        case volume, brightness
        case capsLock(on: Bool)
        case inputSource(from: String, to: String, name: String)
    }

    @Published private(set) var kind: Kind = .volume
    @Published private(set) var level: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var visible = false

    private let tap = MediaKeyTap()
    private var hideWork: DispatchWorkItem?
    private var observedDevice: AudioDeviceID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastShownVolume: (Float, Bool)?
    private var capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
    private var inputSource = HUDController.currentInputSource()

    init() {
        tap.onKey = { [weak self] key, fine in
            self?.handle(key, fineStep: fine) ?? false
        }
        tap.start()
        observeOutputDevice()
        observeKeyboardState()
    }

    // MARK: Caps Lock and keyboard language

    private func observeKeyboardState() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChanged(event.modifierFlags) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputSourceChanged() }
        }
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let on = flags.contains(.capsLock)
        guard on != capsLockOn else { return }
        capsLockOn = on
        flash(.capsLock(on: on))
    }

    private func inputSourceChanged() {
        let current = Self.currentInputSource()
        guard current.code != inputSource.code || current.name != inputSource.name else { return }
        let previous = inputSource
        inputSource = current
        flash(.inputSource(from: previous.code, to: current.code, name: current.name))
    }

    /// Short language code (e.g. "EN", "AR") and display name (e.g. "Arabic") of the active keyboard layout.
    private static func currentInputSource() -> (code: String, name: String) {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func property(_ key: CFString) -> AnyObject? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        }
        let name = property(kTISPropertyLocalizedName) as? String ?? "Keyboard"
        let language = (property(kTISPropertyInputSourceLanguages) as? [String])?.first ?? name
        let code = String(language.prefix(2)).uppercased()
        return (code, name)
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

    private func flash(_ kind: Kind) {
        show(kind, level: Float(level), muted: false, duration: 1.3)
    }

    private func show(_ kind: Kind, level: Float, muted: Bool, duration: Double = 1.6) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
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

    var body: some View {
        Group {
            switch hud.kind {
            case .volume, .brightness:
                levelBar
            case .capsLock(let on):
                HStack(spacing: 10) {
                    Image(systemName: on ? "capslock.fill" : "capslock")
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 22)
                    Text(on ? "Caps Lock On" : "Caps Lock Off")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(on ? 1 : 0.6))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(on ? Color.green : Color.white.opacity(0.2))
                        .frame(width: 7, height: 7)
                }
            case .inputSource(let from, let to, let name):
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22)
                    Text(from)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(to)
                        .font(.system(size: 13, weight: .bold))
                    Spacer(minLength: 4)
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: HUDView.size.width, height: HUDView.size.height)
    }

    private var levelSymbol: String {
        if hud.kind == .volume { return hud.muted ? "speaker.slash.fill" : "speaker.wave.3.fill" }
        return hud.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }

    private var levelBar: some View {
        HStack(spacing: 12) {
            Image(systemName: levelSymbol, variableValue: hud.kind == .volume ? hud.level : nil)
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
    }

    static let size = CGSize(width: 236, height: 40)
}
