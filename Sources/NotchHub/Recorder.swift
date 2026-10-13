import AppKit
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "local.notchhub", category: "recorder")

@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case saved(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var stream: SCStream?
    private var outputURL: URL?
    private var resetWork: DispatchWorkItem?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func toggle() {
        switch phase {
        case .recording: stop()
        case .starting: break
        case .saved(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .idle, .failed: Task { await start() }
        }
    }

    private func start() async {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; afterwards macOS needs it enabled in Settings.
            if !CGRequestScreenCaptureAccess() {
                fail("Allow Screen Recording in System Settings")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }

        phase = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                return fail("No display found")
            }
            // Keep NotchHub itself (including the notch panel used to stop) out of the video.
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = true
            config.capturesAudio = true

            let url = try Self.newRecordingURL()
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = url
            recordingConfig.outputFileType = .mov
            recordingConfig.videoCodecType = .hevc

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addRecordingOutput(SCRecordingOutput(configuration: recordingConfig, delegate: self))
            try await stream.startCapture()

            self.stream = stream
            outputURL = url
            phase = .recording(since: Date())
            log.info("Recording started: \(url.path, privacy: .public)")
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            fail("Couldn't start recording")
        }
    }

    private func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                log.error("Stopping capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func newRecordingURL() throws -> URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/NotchHub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("Screen Recording \(formatter.string(from: Date())).mov")
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        resetSoon(after: 5)
    }

    private func finished() {
        guard let url = outputURL else { return }
        outputURL = nil
        phase = .saved(url)
        log.info("Recording saved")
        resetSoon(after: 8)
    }

    private func resetSoon(after seconds: Double) {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRecording, self.phase != .starting else { return }
                self.phase = .idle
            }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            log.error("Recording failed: \(message, privacy: .public)")
            self.stream = nil
            self.outputURL = nil
            self.fail("Recording failed")
        }
    }
}
