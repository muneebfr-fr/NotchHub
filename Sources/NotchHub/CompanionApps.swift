import AppKit

/// Turns one of the companion apps in this repo (GlassDock, Edge Shelf) on and off, restarting it if it crashes.
@MainActor
final class CompanionApp: ObservableObject {
    @Published private(set) var enabled: Bool

    private let bundleID: String
    private let enabledKey: String
    private let appURL: URL
    /// Runs once the app has quit for good (e.g. GlassDock giving the normal Dock back).
    private let cleanup: (() -> Void)?

    /// Companion apps live in the same checkout: <repo>/build/NotchHub.app → <repo>/<Name>/build/<Name>.app.
    init(name: String, bundleID: String, enabledKey: String, cleanup: (() -> Void)? = nil) {
        self.bundleID = bundleID
        self.enabledKey = enabledKey
        self.cleanup = cleanup
        appURL = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("\(name)/build/\(name).app")
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
        if enabled { launch() } else { finish() }
    }

    static func glassDock() -> CompanionApp {
        CompanionApp(name: "GlassDock", bundleID: "local.glassdock", enabledKey: "glassDockEnabled", cleanup: restoreDockIfNeeded)
    }

    static func edgeShelf() -> CompanionApp {
        CompanionApp(name: "EdgeShelf", bundleID: "local.edgeshelf", enabledKey: "edgeShelfEnabled")
    }

    private static let dockBackupURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GlassDock/original-dock.plist")

    private var stopping = false
    private var recentCrashes: [Date] = []
    private var watch: NSKeyValueObservation?
    /// Held for as long as it's observed: releasing an observed object crashes.
    private var watchedApp: NSRunningApplication?

    var isInstalled: Bool { FileManager.default.fileExists(atPath: appURL.path) }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func finish() {
        if running == nil { cleanup?() }
    }

    func toggle() {
        setEnabled(!enabled)
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            launch()
        } else {
            stopping = true
            running?.terminate()
            // The app tidies up as it quits; this is the safety net if it can't.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
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
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] app, _ in
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
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    /// Puts the user's original Dock settings back if GlassDock left them changed.
    private static func restoreDockIfNeeded() {
        guard let original = NSDictionary(contentsOf: dockBackupURL) as? [String: Any] else { return }
        for key in ["autohide", "autohide-delay"] {
            CFPreferencesSetAppValue(key as CFString, original[key] as CFPropertyList?, "com.apple.dock" as CFString)
        }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        try? FileManager.default.removeItem(at: dockBackupURL)
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }
}
