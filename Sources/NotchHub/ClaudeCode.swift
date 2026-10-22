import Foundation
import SwiftUI

private let claudeEventName = Notification.Name("local.notchhub.claude-code")

/// Runs when NotchHub's binary is invoked by a Claude Code hook (`NotchHub --claude-hook`).
/// It forwards only the event type, session ID and project folder name, never prompt text, then exits.
enum ClaudeHook {
    static var isInvocation: Bool { CommandLine.arguments.contains("--claude-hook") }

    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = json["hook_event_name"] as? String,
              let session = json["session_id"] as? String
        else { return }

        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        // Only the kind of notification is forwarded: permission prompts need you; "waiting for input" idling doesn't.
        let message = (json["message"] as? String ?? "").lowercased()
        let kind = message.contains("permission") ? "permission" : "other"
        DistributedNotificationCenter.default().postNotificationName(
            claudeEventName,
            object: nil,
            userInfo: ["event": event, "session": session, "project": project, "kind": kind],
            deliverImmediately: true
        )
    }
}

@MainActor
final class ClaudeCodeMonitor: ObservableObject {
    enum Status: Hashable {
        case idle
        case working(project: String, sessions: Int)
        case needsInput(project: String)
        case done(project: String)
    }

    @Published private(set) var status: Status = .idle

    private enum SessionState { case working, needsInput, idle }
    private var sessions: [String: (state: SessionState, project: String, updated: Date)] = [:]
    /// Sessions that went quiet this long (e.g. a terminal closed mid-task) stop counting as working.
    private static let staleAfter: TimeInterval = 2 * 60 * 60
    private var lastDone: (project: String, at: Date)?
    private var clearWork: DispatchWorkItem?

    init() {
        DistributedNotificationCenter.default().addObserver(forName: claudeEventName, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.received(info) }
        }
    }

    private func received(_ info: [String: String]) {
        guard let event = info["event"], let session = info["session"] else { return }
        let project = info["project"] ?? ""

        let now = Date()
        switch event {
        case "UserPromptSubmit":
            sessions[session] = (.working, project, now)
        case "Notification":
            guard info["kind"] == "permission" else { return }
            sessions[session] = (.needsInput, project, now)
        case "Stop":
            sessions[session] = (.idle, project, now)
            lastDone = (project, now)
        case "SessionEnd":
            sessions[session] = nil
        default:
            return
        }
        update()
    }

    private func update() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        sessions = sessions.filter { $0.value.updated > cutoff }
        let new: Status
        if let waiting = sessions.values.first(where: { $0.state == .needsInput }) {
            new = .needsInput(project: waiting.project)
        } else {
            let working = sessions.values.filter { $0.state == .working }
            if let first = working.first {
                new = .working(project: first.project, sessions: working.count)
            } else if let done = lastDone, Date().timeIntervalSince(done.at) < 5 {
                new = .done(project: done.project)
                scheduleClear()
            } else {
                new = .idle
            }
        }
        if new != status {
            withAnimation(.spring(duration: 0.5, bounce: 0.18)) { status = new }
        }
    }

    // The "done" tick is a brief flash.
    private func scheduleClear() {
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.lastDone = nil
                self?.update()
            }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

/// Collapsed-notch wing content for Claude Code.
struct ClaudeCodeWings: View {
    let status: ClaudeCodeMonitor.Status

    private static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        HStack {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Self.claudeOrange)
                .frame(width: 20)
            Spacer()
            trailing.frame(width: 22)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .working(_, let count):
            // Static on purpose: a session can work for an hour, and a spinner would redraw the whole time.
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Self.claudeOrange)
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Self.claudeOrange)
            }
        case .needsInput:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .idle:
            EmptyView()
        }
    }
}
