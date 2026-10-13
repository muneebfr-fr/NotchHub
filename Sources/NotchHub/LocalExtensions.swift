import AppKit
import SwiftUI

/// What NotchHub offers to an optional, machine-local add-on.
@MainActor
final class LocalExtensionHost {
    let state: NotchState
    /// The add-on calls this with true when it needs clicks and typing, and false when it's done.
    var setInteractive: (Bool) -> Void = { _ in }

    init(state: NotchState) {
        self.state = state
    }
}

/// An add-on that isn't part of the shared code (for example, a file kept out of git on one machine).
/// It's found at runtime by class name, so the app builds and runs normally without it.
@MainActor
protocol LocalExtension: AnyObject {
    init(host: LocalExtensionHost)
    /// Drawn over the notch area; the add-on decides when it is visible.
    var overlay: AnyView { get }
}

@MainActor
enum LocalExtensions {
    static func load(host: LocalExtensionHost) -> LocalExtension? {
        guard let type = NSClassFromString("NotchHubLocalExtension") as? LocalExtension.Type else { return nil }
        return type.init(host: host)
    }
}
