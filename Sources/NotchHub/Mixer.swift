import AppKit
import AudioToolbox
import CoreAudio
import OSLog
import SwiftUI

private let log = Logger(subsystem: "local.notchhub", category: "mixer")

// MARK: - Core Audio helpers

private enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func pid(_ process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }

    static var defaultOutputDevice: AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }
}

// MARK: - One app's rerouted audio

/// Gain shared with the real-time audio thread. A torn read of a Float is impossible on arm64,
/// so no lock is needed (and a lock would be wrong on the audio thread).
private final class GainBox: @unchecked Sendable {
    var target: Float
    var current: Float
    init(_ value: Float) { target = value; current = value }
}

/// Taps an app's audio (muting its direct output), and plays it back through the current output device
/// at an adjustable gain via a private aggregate device.
private final class TapRoute {
    let processes: [AudioObjectID]
    let outputDevice: AudioDeviceID
    let gain: GainBox

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.notchhub.mixer.io", qos: .userInteractive)

    init?(processes: [AudioObjectID], outputDevice: AudioDeviceID, gain: Float) {
        self.processes = processes
        self.outputDevice = outputDevice
        self.gain = GainBox(gain)

        guard let outputUID = CA.string(outputDevice, kAudioDevicePropertyDeviceUID) else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "NotchHub per-app volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            log.error("Couldn't create an audio tap (System Audio Recording permission may be off)")
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchHub Volume",
            kAudioAggregateDeviceUIDKey: "local.notchhub.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            log.error("Couldn't create the playback device")
            teardown()
            return nil
        }

        let gain = self.gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            Self.render(input: input, output: output, gain: gain)
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else {
            log.error("Couldn't start per-app playback")
            teardown()
            return nil
        }
    }

    /// The tap's stream is the last input buffer (the output device's own inputs, if any, come first).
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: GainBox) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        let start = gain.current
        let end = gain.target
        gain.current = end

        guard let source = inputs.last, let sourceData = source.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let sourceChannels = max(1, Int(source.mNumberChannels))
        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels

        var channelOffset = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let outFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let count = min(frames, outFrames)
            for frame in 0..<outFrames {
                // Ramp across the buffer so level changes never click.
                let g = count > 1 ? start + (end - start) * Float(frame) / Float(count - 1) : end
                for channel in 0..<channels {
                    let sourceChannel = (channelOffset + channel) % sourceChannels
                    data[frame * channels + channel] = frame < count
                        ? sourceData[frame * sourceChannels + sourceChannel] * g
                        : 0
                }
            }
            channelOffset += channels
        }
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { teardown() }
}

// MARK: - Mixer

@MainActor
final class VolumeMixer: ObservableObject {
    struct AppAudio: Identifiable, Hashable {
        let id: String
        let name: String
        let icon: NSImage?
        let processes: [AudioObjectID]
        let playing: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.processes == rhs.processes && lhs.playing == rhs.playing
        }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @Published private(set) var apps: [AppAudio] = []
    @Published private(set) var levels: [String: Float]

    private var routes: [String: TapRoute] = [:]
    private static let levelsKey = "appVolumes"

    init() {
        levels = UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Float] ?? [:]
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func level(for app: AppAudio) -> Float { levels[app.id] ?? 1 }

    func setLevel(_ value: Float, for app: AppAudio) {
        let value = min(max(value, 0), 1)
        levels[app.id] = value >= 0.995 ? nil : value
        UserDefaults.standard.set(levels, forKey: Self.levelsKey)
        if let route = routes[app.id], levels[app.id] != nil {
            route.gain.target = value
        } else {
            updateRoutes()
        }
    }

    func toggleMute(_ app: AppAudio) {
        setLevel(level(for: app) == 0 ? 1 : 0, for: app)
    }

    /// Re-reads which apps use audio; called on Core Audio changes and while the mixer is on screen.
    func refresh() {
        var grouped: [String: (name: String, icon: NSImage?, processes: [AudioObjectID], playing: Bool)] = [:]
        for process in CA.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CA.pid(process), pid != getpid(), let app = Self.app(for: pid) else { continue }
            let playing = CA.uint32(process, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 } ?? false
            var entry = grouped[app.id] ?? (app.name, app.icon, [], false)
            entry.processes.append(process)
            entry.playing = entry.playing || playing
            grouped[app.id] = entry
        }

        // Playing apps first, then ones you've adjusted; everything else stays out of the list.
        let new = grouped
            .map { AppAudio(id: $0.key, name: $0.value.name, icon: $0.value.icon, processes: $0.value.processes.sorted(), playing: $0.value.playing) }
            .filter { $0.playing || levels[$0.id] != nil }
            .sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
        if new != apps { apps = new }
        updateRoutes(grouped.mapValues(\.processes))
    }

    private func updateRoutes(_ processesByApp: [String: [AudioObjectID]]? = nil) {
        let processesByApp = processesByApp ?? Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.processes) })
        guard let output = CA.defaultOutputDevice else { return }

        for (id, route) in routes {
            let wanted = levels[id] != nil ? processesByApp[id]?.sorted() : nil
            if wanted != route.processes || route.outputDevice != output { routes[id] = nil }
        }
        for (id, level) in levels where routes[id] == nil {
            guard let processes = processesByApp[id]?.sorted(), !processes.isEmpty else { continue }
            routes[id] = TapRoute(processes: processes, outputDevice: output, gain: level)
            if routes[id] != nil { log.info("Volume control active for an app (\(Int(level * 100), privacy: .public)%)") }
        }
    }

    /// Attributes helper processes (e.g. a browser's audio service) to the outermost app bundle.
    private static func app(for pid: pid_t) -> (id: String, name: String, icon: NSImage?)? {
        let running = NSRunningApplication(processIdentifier: pid)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let path = running?.bundleURL?.path
            ?? (proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil)
        guard let path, let range = path.range(of: ".app") else { return nil }
        let appPath = String(path[..<range.upperBound])
        // System daemons (e.g. inside /System/Library) aren't something you'd want a slider for.
        guard appPath.hasPrefix("/Applications") || appPath.hasPrefix("/System/Applications")
                || appPath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications")
        else { return nil }
        let id = Bundle(path: appPath)?.bundleIdentifier ?? appPath
        let name = (FileManager.default.displayName(atPath: appPath) as NSString).deletingPathExtension
        return (id, name, NSWorkspace.shared.icon(forFile: appPath))
    }
}

// MARK: - View

struct MixerCard: View {
    @EnvironmentObject var mixer: VolumeMixer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Volume")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.42))
                .frame(height: 14)

            if mixer.apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 20, weight: .light))
                    Text("Apps playing sound show up here")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(mixer.apps) { app in MixerRow(app: app) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        // Apps start and stop sound without any notification for "started playing", so check while visible.
        .task {
            while !Task.isCancelled {
                mixer.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct MixerRow: View {
    @EnvironmentObject var mixer: VolumeMixer
    let app: VolumeMixer.AppAudio

    var body: some View {
        let level = mixer.level(for: app)
        HStack(spacing: 9) {
            Button { mixer.toggleMute(app) } label: {
                ZStack(alignment: .bottomTrailing) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                    if level < 1 {
                        Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 7, weight: .bold))
                            .padding(2)
                            .background(Circle().fill(Color.black.opacity(0.75)))
                            .offset(x: 4, y: 3)
                    }
                }
                .opacity(app.playing ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .help(level == 0 ? "Unmute \(app.name)" : "Mute \(app.name)")

            Slider(
                value: Binding(get: { Double(level) }, set: { mixer.setLevel(Float($0), for: app) }),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(.white)

            Text(level == 0 ? "Muted" : "\(Int((level * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(level < 1 ? 0.9 : 0.5))
                .frame(width: 38, alignment: .trailing)
        }
        .help(app.name)
    }
}
