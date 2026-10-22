import Accelerate
import AppKit
import CoreAudio
import OSLog

private let log = Logger(subsystem: "local.notchhub", category: "visualizer")

/// Four smoothed frequency-band levels (0…1), written by the audio thread and read by the UI.
/// Fixed raw storage, so the audio thread never allocates or takes a lock.
final class BandLevels: @unchecked Sendable {
    static let count = 4
    let values = UnsafeMutablePointer<Float>.allocate(capacity: BandLevels.count)

    init() { values.initialize(repeating: 0, count: Self.count) }
    deinit { values.deallocate() }

    func reset() { values.update(repeating: 0, count: Self.count) }
}

/// Listens (without muting) to the music player's audio and turns it into band levels.
/// Only runs while the equalizer is on screen.
@MainActor
final class AudioVisualizer: ObservableObject {
    let bands = BandLevels()
    private(set) var isLive = false
    private var analyzer: BandAnalyzer?
    private var users = 0
    private var player: String?

    private static let bundleIDs = ["Spotify": "com.spotify.client", "Music": "com.apple.Music"]

    func start(for player: String?) {
        users += 1
        if player != self.player || analyzer == nil { restart(player) }
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 {
            analyzer = nil
            isLive = false
            bands.reset()
        }
    }

    func playerChanged(_ player: String?) {
        if users > 0, player != self.player { restart(player) }
    }

    private func restart(_ player: String?) {
        self.player = player
        analyzer = nil
        bands.reset()
        guard let player, let bundleID = Self.bundleIDs[player] else {
            isLive = false
            return
        }
        analyzer = BandAnalyzer(bundleIDPrefix: bundleID, bands: bands)
        isLive = analyzer != nil
        if !isLive { log.info("Visualizer unavailable; using the idle animation") }
    }
}

/// A non-muting tap on one app's processes, analysed with a small FFT on the audio thread.
private final class BandAnalyzer {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.notchhub.visualizer", qos: .userInteractive)
    private var dsp: DSP?

    init?(bundleIDPrefix: String, bands: BandLevels) {
        let processes = Self.processes(matching: bundleIDPrefix)
        guard !processes.isEmpty, let output = Self.defaultOutputUID() else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "NotchHub visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchHub Visualizer",
            kAudioAggregateDeviceUIDKey: "local.notchhub.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            teardown()
            return nil
        }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(48_000)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &rateSize, &rate)

        let dsp = DSP(sampleRate: Float(rate), bands: bands)
        self.dsp = dsp
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            // Nothing is played through this device; output stays silent.
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if let tap = inputs.last { dsp.consume(tap) }
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else {
            teardown()
            return nil
        }
    }

    private static func processes(matching prefix: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { process in
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: CFString = "" as CFString
            var valueSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &valueSize, $0)
            }
            return status == noErr && (value as String).hasPrefix(prefix)
        }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return nil
        }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
        }
        return status == noErr ? uid as String : nil
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { teardown() }
}

/// Real-time-safe band analysis: everything is preallocated; consume() only does arithmetic.
private final class DSP: @unchecked Sendable {
    private static let log2n: vDSP_Length = 10
    private static let n = 1 << 10

    private let setup: FFTSetup
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: DSP.n)
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: DSP.n)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: DSP.n)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: DSP.n / 2)
    private let imag = UnsafeMutablePointer<Float>.allocate(capacity: DSP.n / 2)
    private let magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: DSP.n / 2)
    private var ringIndex = 0
    private var samplesSinceFFT = 0
    private let binRanges: [(Int, Int)]
    private let bands: BandLevels

    init(sampleRate: Float, bands: BandLevels) {
        self.bands = bands
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(window, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
        ring.initialize(repeating: 0, count: Self.n)
        // Bass, low-mids, high-mids, treble.
        let edges: [Float] = [40, 250, 1_200, 4_500, 14_000]
        let binWidth = sampleRate / Float(Self.n)
        binRanges = (0..<4).map { i in
            let lo = max(1, Int(edges[i] / binWidth))
            let hi = min(Self.n / 2 - 1, max(lo + 1, Int(edges[i + 1] / binWidth)))
            return (lo, hi)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        [window, ring, frame, real, imag, magnitudes].forEach { $0.deallocate() }
    }

    func consume(_ buffer: AudioBuffer) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += data[i * channels + c] }
            ring[ringIndex] = sum / Float(channels)
            ringIndex = (ringIndex + 1) & (Self.n - 1)
        }
        samplesSinceFFT += frames
        // About 40 analyses a second is plenty for 30 fps bars.
        if samplesSinceFFT >= 1_024 {
            samplesSinceFFT = 0
            analyze()
        }
    }

    private func analyze() {
        let n = Self.n
        let tail = n - ringIndex
        frame.update(from: ring + ringIndex, count: tail)
        (frame + tail).update(from: ring, count: ringIndex)
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: real, imagp: imag)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(n / 2))

        for (i, range) in binRanges.enumerated() {
            var peak: Float = 0
            vDSP_maxv(magnitudes + range.0, 1, &peak, vDSP_Length(range.1 - range.0))
            // Power to dB, mapped from -50…0 dB onto 0…1, with treble boosted a little since it's naturally quieter.
            let db = 10 * log10f(max(peak, 1e-12) / Float(n))
            let level = min(1, max(0, (db + 50 + Float(i) * 4) / 50))
            let previous = bands.values[i]
            // Jump up instantly, fall back gently.
            bands.values[i] = level > previous ? level : previous * 0.82 + level * 0.18
        }
    }
}
