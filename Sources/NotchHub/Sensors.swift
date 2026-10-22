import AppKit
import ApplicationServices
import CoreAudio
import CoreMediaIO
import OSLog

private let log = Logger(subsystem: "local.notchhub", category: "sensors")

struct SensorApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Watches whether the camera or microphone is in use, and by which apps. Entirely event-driven.
@MainActor
final class SensorMonitor: ObservableObject {
    @Published private(set) var cameraOn = false
    @Published private(set) var micOn = false
    @Published private(set) var cameraApps: [SensorApp] = []
    @Published private(set) var micApps: [SensorApp] = []

    var isActive: Bool { cameraOn || micOn }

    /// Everyone using either sensor, without duplicates (a video call usually holds both).
    var apps: [SensorApp] {
        var seen = Set<String>()
        return (cameraApps + micApps).filter { seen.insert($0.id).inserted }
    }

    private var cameraIDs: [CMIOObjectID] = []
    private var inputDevice: AudioDeviceID?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var refreshWork: DispatchWorkItem?

    init() {
        observeCameras()
        observeMicrophone()
        refresh()
    }

    // MARK: Camera (CoreMediaIO)

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func observeCameras() {
        var devices = Self.cmioAddress(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devices, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindCameras() }
        }
        bindCameras()
    }

    private func bindCameras() {
        let ids = Self.cameraDeviceIDs()
        for id in ids where !cameraIDs.contains(id) {
            var running = Self.cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectAddPropertyListenerBlock(id, &running, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        cameraIDs = ids
        scheduleRefresh()
    }

    private static func cameraDeviceIDs() -> [CMIOObjectID] {
        var address = cmioAddress(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
        return ids
    }

    private static func cameraIsRunning(_ id: CMIOObjectID) -> Bool {
        var address = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0
            && value != 0
    }

    /// macOS has no public API naming the app using the camera, but its own privacy indicator in the menu bar
    /// does. This reads that indicator's accessibility text and matches it against running apps.
    private static func cameraAppsFromPrivacyIndicator() -> [SensorApp] {
        guard AXIsProcessTrusted(),
              let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return [] }

        let element = AXUIElementCreateApplication(controlCenter.processIdentifier)
        var extrasValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &extrasValue) == .success,
              let extras = extrasValue, CFGetTypeID(extras) == AXUIElementGetTypeID()
        else { return [] }

        let keywords = ["camera", "microphone", "privacy", "in use", "recording"]
        let indicatorText = children(of: extras as! AXUIElement)
            .map { item in
                [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
                    .compactMap { string(item, $0) }
                    .joined(separator: " ")
            }
            .filter { text in keywords.contains { text.lowercased().contains($0) } }
            .joined(separator: " | ")
        log.info("Privacy indicator text: \(indicatorText, privacy: .public)")

        let lowered = indicatorText.lowercased()
        guard !lowered.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in
                guard let name = app.localizedName, lowered.contains(name.lowercased()) else { return nil }
                return SensorApp(id: app.bundleURL?.path ?? name, name: name, icon: app.icon)
            }
    }

    // MARK: Microphone (CoreAudio)

    private func observeMicrophone() {
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindInputDevice() }
        }
        // Apps starting or stopping audio change the process list, which keeps the app list current mid-call.
        var processes = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processes, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        bindInputDevice()
    }

    private static func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func bindInputDevice() {
        if let device = inputDevice, let listener = inputListener {
            var address = Self.runningAddress()
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0
        else {
            inputDevice = nil
            return
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        var running = Self.runningAddress()
        AudioObjectAddPropertyListenerBlock(device, &running, .main, listener)
        inputDevice = device
        inputListener = listener
        scheduleRefresh()
    }

    private static func inputIsRunning(_ device: AudioDeviceID) -> Bool {
        var address = runningAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Core Audio reports exactly which processes are capturing audio input.
    private static func microphoneApps() -> [SensorApp] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        var seen = Set<String>()
        return processes.compactMap { process -> SensorApp? in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &inputAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else {
                return nil
            }
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return nil }
            return app(for: pid)
        }
        .filter { seen.insert($0.id).inserted }
    }

    /// Maps a process to the app the user would recognise: helpers (e.g. a browser's audio helper) are
    /// attributed to the outermost app bundle that contains them.
    private static func app(for pid: pid_t) -> SensorApp? {
        guard pid != getpid() else { return nil }
        let running = NSRunningApplication(processIdentifier: pid)
        let path = running?.bundleURL?.path ?? running?.executableURL?.path ?? executablePath(of: pid)
        if let path, let range = path.range(of: ".app") {
            let appPath = String(path[..<range.upperBound])
            let name = (FileManager.default.displayName(atPath: appPath) as NSString).deletingPathExtension
            return SensorApp(id: appPath, name: name, icon: NSWorkspace.shared.icon(forFile: appPath))
        }
        guard let name = running?.localizedName else { return nil }
        return SensorApp(id: name, name: name, icon: running?.icon)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: State

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh() {
        let camera = cameraIDs.contains(where: Self.cameraIsRunning)
        let mic = inputDevice.map(Self.inputIsRunning) ?? false

        let newMicApps = mic ? Self.microphoneApps() : []
        if newMicApps != micApps { micApps = newMicApps }
        if mic != micOn { micOn = mic }

        if camera {
            let newCameraApps = Self.cameraAppsFromPrivacyIndicator()
            if newCameraApps != cameraApps { cameraApps = newCameraApps }
            // The menu bar indicator can appear a moment after the camera starts; look once more.
            if newCameraApps.isEmpty, !cameraOn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.cameraOn, self.cameraApps.isEmpty else { return }
                        let retry = Self.cameraAppsFromPrivacyIndicator()
                        if !retry.isEmpty { self.cameraApps = retry }
                    }
                }
            }
        } else if !cameraApps.isEmpty {
            cameraApps = []
        }
        if camera != cameraOn { cameraOn = camera }
    }

    // MARK: AX helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
