import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct XcodeStatus: Hashable {
    enum State: Hashable { case idle, building, succeeded, failed }
    var project: String
    var state: State
    var errors: Int
    var warnings: Int
}

/// Knows which app is in front and offers app-specific controls for it, plus live Xcode build status.
@MainActor
final class AppContextMonitor: ObservableObject {
    enum Context: Equatable {
        case none
        case xcode(XcodeStatus)
        case browser(bundleID: String, title: String, url: URL)
    }

    @Published private(set) var context: Context = .none
    /// Shown in the collapsed notch while building and briefly after a build finishes.
    @Published private(set) var xcodeWing: XcodeStatus?

    var hasStrip: Bool { context != .none }

    private static let xcodeID = "com.apple.dt.Xcode"
    private static let browsers: [String: String] = [
        "com.apple.Safari": """
            tell application "Safari" to return (URL of current tab of front window) & linefeed & (name of current tab of front window)
            """,
        "com.google.Chrome": """
            tell application "Google Chrome" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)
            """,
    ]

    private var frontmostID: String?
    private var xcode: XcodeStatus?
    private var xcodeTimer: Timer?
    private var wingClear: DispatchWorkItem?

    init() {
        frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app?.bundleIdentifier) }
        }
        // Xcode is only queried while it's running; the build state has no change notification.
        xcodeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollXcode() }
        }
        refresh()
    }

    private func activated(_ bundleID: String?) {
        // NotchHub itself never counts as "the app in front".
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        frontmostID = bundleID
        refresh()
    }

    /// Recomputes the context for the frontmost app (also called when the panel opens).
    func refresh() {
        if frontmostID == Self.xcodeID, let xcode {
            setContext(.xcode(xcode))
        } else if let id = frontmostID, let script = Self.browsers[id] {
            BackgroundAppleScript.shared.run(script) { [weak self] output in
                // Ignore the answer if the user has already switched to another app.
                guard let self, self.frontmostID == id else { return }
                let parts = (output ?? "").components(separatedBy: "\n")
                if let url = parts.first.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                    self.setContext(.browser(bundleID: id, title: parts.dropFirst().joined(separator: " "), url: url))
                } else {
                    self.setContext(.none)
                }
            }
        } else {
            setContext(.none)
        }
    }

    private func setContext(_ new: Context) {
        if new != context { context = new }
    }

    // MARK: Xcode

    private func pollXcode() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeID).isEmpty else {
            if xcode != nil { xcode = nil }
            return
        }
        BackgroundAppleScript.shared.run("""
        tell application "Xcode"
            set ws to active workspace document
            if ws is missing value then return ""
            set r to last scheme action result of ws
            if r is missing value then return (name of ws) & linefeed & "none" & linefeed & "0" & linefeed & "0"
            return (name of ws) & linefeed & (status of r as string) & linefeed & ((count of build errors of r) as string) & linefeed & ((count of build warnings of r) as string)
        end tell
        """) { [weak self] output in
            guard let output, !output.isEmpty else { return }
            self?.applyXcode(output)
        }
    }

    private func applyXcode(_ output: String) {
        let parts = output.components(separatedBy: "\n")
        guard parts.count == 4 else { return }
        let state: XcodeStatus.State = switch parts[1] {
        case "running": .building
        case "succeeded": .succeeded
        case "failed", "error occurred": .failed
        default: .idle
        }
        let status = XcodeStatus(project: parts[0], state: state, errors: Int(parts[2]) ?? 0, warnings: Int(parts[3]) ?? 0)
        let previous = xcode?.state
        guard status != xcode else { return }
        xcode = status

        if state == .building {
            setWing(status)
        } else if previous == .building {
            // Finished: flash the result for a few seconds.
            setWing(status)
            wingClear?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.setWing(nil) }
            }
            wingClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
        if frontmostID == Self.xcodeID { refresh() }
    }

    private func setWing(_ status: XcodeStatus?) {
        withAnimation(.spring(duration: 0.5, bounce: 0.18)) { xcodeWing = status }
    }

    func xcodeAction(_ verb: String) {
        BackgroundAppleScript.shared.run("tell application \"Xcode\" to \(verb) active workspace document") { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.pollXcode() }
        }
    }

    // MARK: Browser

    static func qrCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

// MARK: - Views

/// Bottom strip of the open panel with controls for the app in front.
struct ContextStrip: View {
    @EnvironmentObject var context: AppContextMonitor

    var body: some View {
        Group {
            switch context.context {
            case .xcode(let status): XcodeStrip(status: status)
            case .browser(let id, let title, let url): BrowserStrip(bundleID: id, title: title, url: url)
            case .none: EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

private struct AppBadge: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.fill").resizable()
            }
        }
        .frame(width: 32, height: 32)
    }
}

private struct StripButton: View {
    let title: String
    let symbol: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct XcodeStrip: View {
    @EnvironmentObject var context: AppContextMonitor
    let status: XcodeStatus

    private var summary: (String, Color) {
        switch status.state {
        case .building: return ("Building…", .white.opacity(0.7))
        case .succeeded: return (status.warnings > 0 ? "Build succeeded · \(status.warnings) warnings" : "Build succeeded", .green)
        case .failed: return ("\(status.errors) error\(status.errors == 1 ? "" : "s") · \(status.warnings) warnings", .red)
        case .idle: return ("Ready", .white.opacity(0.6))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AppBadge(bundleID: "com.apple.dt.Xcode")
            VStack(alignment: .leading, spacing: 2) {
                Text(status.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(summary.0).font(.system(size: 11, weight: .medium)).foregroundStyle(summary.1)
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    StripButton(title: "Build", symbol: "hammer.fill") { context.xcodeAction("build") }
                    StripButton(title: "Run", symbol: "play.fill") { context.xcodeAction("run") }
                    if status.state == .building {
                        StripButton(title: "Stop", symbol: "stop.fill", tint: .red) { context.xcodeAction("stop") }
                    }
                }
            }
        }
    }
}

private struct BrowserStrip: View {
    let bundleID: String
    let title: String
    let url: URL
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            AppBadge(bundleID: bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? url.host() ?? url.absoluteString : title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(url.host() ?? url.absoluteString)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StripButton(title: copied ? "Copied" : "Copy link", symbol: copied ? "checkmark" : "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copied = true
            }
            if let qr = AppContextMonitor.qrCode(for: url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .padding(3)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    .help("Scan with your phone to open this page")
            }
        }
        .onChange(of: url) { copied = false }
    }
}

/// Collapsed-notch wing content while Xcode builds or just finished.
struct XcodeWings: View {
    let status: XcodeStatus

    var body: some View {
        HStack {
            Image(systemName: "hammer.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.35, green: 0.62, blue: 1))
                .frame(width: 20)
            Spacer()
            Group {
                switch status.state {
                case .building:
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .symbolEffect(.bounce, options: .nonRepeating)
                case .failed:
                    Text("\(status.errors)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 22)
        }
    }
}
