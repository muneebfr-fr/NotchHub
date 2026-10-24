import AppKit
import Combine
import FoundationModels
import NaturalLanguage
import SwiftUI
import Vision

/// Clipboard superpowers: after a copy, a small glass pill offers actions (fix grammar, summarize, translate,
/// open a link on your phone, extract text from an image). Everything runs on-device with Apple's model and
/// Vision; results go onto the clipboard as a new history item, so the original is never lost.
@MainActor
final class ClipboardActions: ObservableObject {
    enum Action: Hashable, Identifiable {
        case fixGrammar, summarize, translate(to: String), openOnPhone, extractText

        var id: String { title }

        var title: String {
            switch self {
            case .fixGrammar: "Fix grammar"
            case .summarize: "Summarize"
            case .translate(let language): "Translate → \(language)"
            case .openOnPhone: "Open on phone"
            case .extractText: "Extract text"
            }
        }

        var symbol: String {
            switch self {
            case .fixGrammar: "checkmark.seal"
            case .summarize: "text.badge.star"
            case .translate: "character.bubble"
            case .openOnPhone: "qrcode"
            case .extractText: "text.viewfinder"
            }
        }

        var progressTitle: String {
            switch self {
            case .fixGrammar: "Fixing grammar…"
            case .summarize: "Summarizing…"
            case .translate: "Translating…"
            case .openOnPhone: ""
            case .extractText: "Reading text…"
            }
        }
    }

    enum Phase: Equatable {
        case suggesting
        case working(Action)
        case done(String)
        case qr(NSImage)
        case failed(String)
    }

    struct Suggestion: Identifiable {
        let id = UUID()
        let text: String?
        let image: ClipImage?
        let actions: [Action]
    }

    @Published private(set) var suggestion: Suggestion?
    @Published private(set) var phase: Phase = .suggesting
    /// The pill's frame in the notch window's top-left coordinates (not published: never triggers a render).
    var pillRect: CGRect = .zero
    var hovering = false {
        didSet { hovering ? dismissWork?.cancel() : scheduleDismiss() }
    }

    private let store: ClipboardStore
    private var dismissWork: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: ClipboardStore) {
        self.store = store
        store.$freshCopy
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] copy in
                MainActor.assumeIsolated { self?.offer(text: copy.text, image: copy.image) }
            }
            .store(in: &cancellables)
    }

    // MARK: Suggestions

    /// Which actions make sense for this clip (nothing for a lone word or a number).
    static func actions(for text: String?, image: ClipImage?) -> [Action] {
        if image != nil { return [.extractText] }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        if let url = URL(string: text), url.scheme?.hasPrefix("http") == true, !text.contains(" ") { return [.openOnPhone] }
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        guard words >= 3, text.contains(where: \.isLetter) else { return [] }
        var actions: [Action] = [.fixGrammar]
        if text.count >= 280 { actions.append(.summarize) }
        actions.append(.translate(to: translationTarget(for: text)))
        return actions
    }

    /// English text goes to Arabic; anything else comes back to English.
    private static func translationTarget(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english ? "Arabic" : "English"
    }

    private func offer(text: String?, image: ClipImage?) {
        // Don't interrupt something that's running or a QR code that's being scanned.
        if case .working = phase, suggestion != nil { return }
        if case .qr = phase, suggestion != nil { return }
        let actions = Self.actions(for: text, image: image)
        guard !actions.isEmpty else { return }
        present(Suggestion(text: text, image: image, actions: actions))
        scheduleDismiss(after: 6)
    }

    /// Opens the pill straight to an action (used from the clipboard card in the panel).
    func perform(_ action: Action, text: String? = nil, image: ClipImage? = nil) {
        present(Suggestion(text: text, image: image, actions: [action]))
        run(action)
    }

    private func present(_ new: Suggestion) {
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
            suggestion = new
            phase = .suggesting
        }
    }

    func dismiss() {
        dismissWork?.cancel()
        task?.cancel()
        withAnimation(.spring(duration: 0.35, bounce: 0)) { suggestion = nil }
    }

    private func scheduleDismiss(after seconds: Double? = nil) {
        guard suggestion != nil, !hovering else { return }
        if case .working = phase { return }
        let delay: Double = seconds ?? {
            switch phase {
            case .done: 1.8
            case .qr: 4
            case .failed: 3
            default: 2.5
            }
        }()
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Running

    func run(_ action: Action) {
        guard let suggestion else { return }
        dismissWork?.cancel()
        if case .openOnPhone = action {
            if let text = suggestion.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let qr = AppContextMonitor.qrCode(for: url) {
                set(.qr(qr))
                scheduleDismiss(after: 12)
            }
            return
        }
        set(.working(action))
        let text = suggestion.text
        let image = suggestion.image
        task = Task { [weak self] in
            do {
                let result: String
                switch action {
                case .extractText:
                    guard let image else { throw ActionError.nothing }
                    result = try await Self.recognizeText(in: image.data)
                case .fixGrammar:
                    result = try await Self.ask("Correct the spelling, grammar and punctuation of the user's text. Keep its meaning, tone, formatting and language. Reply with only the corrected text.", text)
                case .summarize:
                    result = try await Self.ask("Summarize the user's text in two to four short bullet points that start with \"• \". Reply with only the summary.", text)
                case .translate(let language):
                    result = try await Self.ask("Translate the user's text into \(language). Keep formatting. Reply with only the translation.", text)
                case .openOnPhone:
                    return
                }
                guard let self, !Task.isCancelled else { return }
                let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw ActionError.nothing }
                self.store.copy(clean)
                self.set(.done(clean))
                self.scheduleDismiss()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.set(.failed(Self.message(for: error)))
                self.scheduleDismiss()
            }
        }
    }

    private func set(_ new: Phase) {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { phase = new }
    }

    private enum ActionError: Error { case nothing, unavailable }

    private static func message(for error: Error) -> String {
        if let error = error as? ActionError, error == .unavailable { return "Apple Intelligence isn't available" }
        if error is LanguageModelSession.GenerationError { return "Couldn't do that with this text" }
        return "Nothing to work with"
    }

    /// Apple's on-device model; long text is trimmed to what it can take in one go.
    private static func ask(_ instructions: String, _ text: String?) async throws -> String {
        guard let text, !text.isEmpty else { throw ActionError.nothing }
        guard case .available = SystemLanguageModel.default.availability else { throw ActionError.unavailable }
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: String(text.prefix(6000)))
        return response.content
    }

    /// On-device text recognition, any language Vision supports.
    nonisolated private static func recognizeText(in data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(data: data).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - The pill

struct ClipboardActionPill: View {
    @EnvironmentObject var actions: ClipboardActions

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .foregroundStyle(.white)
            .fixedSize()
            .onHover { actions.hovering = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.pillRect = $0 }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: actions.phase)
    }

    @ViewBuilder private var content: some View {
        switch actions.phase {
        case .suggesting:
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.8, green: 0.86, blue: 1))
                    .padding(.horizontal, 4)
                ForEach(actions.suggestion?.actions ?? []) { action in
                    Button { actions.run(action) } label: {
                        Label(action.title, systemImage: action.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(HoverButtonStyle(radius: 14))
                }
                Button { actions.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        case .working(let action):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(action.progressTitle).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 6)
        case .done(let result):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Copied").font(.system(size: 12, weight: .semibold))
                    Text(result.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }
            .padding(.horizontal, 6)
        case .qr(let image):
            VStack(spacing: 8) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(6)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Scan to open on your phone").font(.system(size: 11, weight: .medium))
            }
            .padding(4)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
        }
    }
}
