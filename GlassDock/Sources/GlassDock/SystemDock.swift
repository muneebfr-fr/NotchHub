import Foundation

/// Earlier versions of GlassDock hid the macOS Dock. This puts the user's original settings back if a backup
/// from those versions is still around; GlassDock itself now leaves the Dock completely alone.
enum SystemDock {
    static let backupURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GlassDock/original-dock.plist")

    private static let keys = ["autohide", "autohide-delay"]

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
