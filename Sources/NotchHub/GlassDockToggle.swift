import AppKit

/// Turns GlassDock (a separate app) on and off. Off always means the normal macOS Dock is back.
@MainActor
final class GlassDockController: ObservableObject {
    @Published private(set) var enabled: Bool

    nonisolated private static let bundleID = "local.glassdock"
    private static let enabledKey = "glassDockEnabled"
    private static let appURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("GlassDock/build/GlassDock.app")
    private static let backupURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GlassDock/original-dock.plist")

    private var stopping = false
    private var recentCrashes: [Date] = []
    private var watch: NSKeyValueObservation?
    /// Held for as long as it's observed: releasing an observed object crashes.
    private var watchedApp: NSRunningApplication?

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.appURL.path) }

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled { launch() } else { restoreDockIfNeeded() }
    }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    func toggle() {
        setEnabled(!enabled)
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            launch()
        } else {
            stopping = true
            running?.terminate()
            // GlassDock restores the Dock as it quits; this is the safety net if it can't.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.restoreDockIfNeeded() }
            }
        }
    }

    private func launch() {
        if let existing = running {
            if watch == nil { observe(existing) }
            return
        }
        guard isInstalled else { return }
        stopping = false
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Self.appURL, configuration: configuration) { [weak self] app, _ in
            guard let app else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observe(app) }
            }
        }
    }

    /// Background apps don't produce workspace quit notifications, so the process itself is watched.
    private func observe(_ app: NSRunningApplication) {
        watch?.invalidate()
        watchedApp = app
        watch = app.observe(\.isTerminated, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.watch?.invalidate()
                    self?.watch = nil
                    self?.watchedApp = nil
                    self?.glassDockExited()
                }
            }
        }
    }

    /// If GlassDock crashes while on, bring it back, unless it keeps crashing, in which case give the Dock back.
    private func glassDockExited() {
        defer { stopping = false }
        guard enabled, !stopping else { return }
        recentCrashes = recentCrashes.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        if recentCrashes.count >= 3 {
            setEnabled(false)
            restoreDockIfNeeded()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    /// Puts the user's original Dock settings back if GlassDock left them changed.
    private func restoreDockIfNeeded() {
        guard running == nil, let original = NSDictionary(contentsOf: Self.backupURL) as? [String: Any] else { return }
        for key in ["autohide", "autohide-delay"] {
            CFPreferencesSetAppValue(key as CFString, original[key] as CFPropertyList?, "com.apple.dock" as CFString)
        }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        try? FileManager.default.removeItem(at: Self.backupURL)
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }
}
