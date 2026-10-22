import Foundation

/// Hides the macOS Dock while GlassDock runs and restores the user's exact settings afterwards.
/// The original values are saved to a file so they can be restored even after a crash (NotchHub reads it too).
enum SystemDock {
    static let backupURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GlassDock/original-dock.plist")

    private static let keys = ["autohide", "autohide-delay"]

    static func hide() {
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            var original: [String: Any] = [:]
            for key in keys {
                if let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) {
                    original[key] = value
                }
            }
            try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An empty dictionary is still written: it records "these keys were unset".
            (original as NSDictionary).write(to: backupURL, atomically: true)
        }
        // Auto-hide with an effectively infinite delay: the Dock never appears, but keeps running normally.
        run("/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "true")
        run("/usr/bin/defaults", "write", "com.apple.dock", "autohide-delay", "-float", "1000")
        run("/usr/bin/killall", "Dock")
    }

    static func restore() {
        guard let original = NSDictionary(contentsOf: backupURL) as? [String: Any] else { return }
        for key in keys {
            if let value = original[key] {
                CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, "com.apple.dock" as CFString)
            } else {
                CFPreferencesSetAppValue(key as CFString, nil, "com.apple.dock" as CFString)
            }
        }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        try? FileManager.default.removeItem(at: backupURL)
        run("/usr/bin/killall", "Dock")
    }

    private static func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
