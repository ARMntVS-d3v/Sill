import AppKit
import SwiftUI

// Conversation with the model. One per app: the bar in the panel and the expanded
// screen are two views of the same conversation, not two separate chats.
//
// Context is kept, but not forever: only the most recent messages go into the
// request, older history gets trimmed. An unbounded chat is a bill that grows
// on its own.
@MainActor @Observable
final class AskSession {
    static let shared = AskSession()

    struct Message: Codable, Identifiable, Sendable, Equatable {
        enum Role: String, Codable, Sendable { case user, model }
        var id = UUID()
        var role: Role
        var text: String
    }

    /// How many messages go into the request along with the new question
    private static let contextLimit = 12
    /// After how much silence the next question counts as a new conversation.
    /// Closing the panel isn't a good signal for this: it gets closed a dozen
    /// times an hour to copy something or switch boards, while the train of
    /// thought stays the same
    private static let contextExpiry: TimeInterval = 15 * 60
    /// How many messages we keep on disk across launches
    private static let keepLimit = 40

    private(set) var messages: [Message] = []
    @ObservationIgnored private var lastAsked = Date.distantPast
    private(set) var isAsking = false
    private(set) var failure: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Request generation number. Cancelling an async stream is cooperative: the
    /// old task can keep running for a bit and its chunks would land in the
    /// last message — i.e. the new question
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let store = UserDefaults.standard
    @ObservationIgnored private let key = "ask.messages"

    private init() {
        if let data = store.data(forKey: key),
           let saved = try? JSONDecoder().decode([Message].self, from: data) {
            messages = saved
        }
    }

    var isEmpty: Bool { messages.isEmpty }
    var provider: LLMProvider { AppSettings.shared.llmProvider }
    /// Check the key via a flag, not by reading the Keychain: reading it can pop
    /// a password prompt and freeze the app mid-panel-render
    // Only trust this when we actually know there's no key: `nil` means not asked yet
    var needsKey: Bool { provider.needsKey && LLMClient.shared.hasKey == false }

    /// The typed but not yet sent question. Lives in the session, not in the bar
    /// itself: the clipboard board has no "Ask" bar at all, its view gets torn
    /// down along with its state — the text used to vanish on a swipe to the
    /// clipboard board and back
    var draft = ""

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }

        // Long silence — start the conversation over so old context doesn't
        // bleed into the new thought (and doesn't get billed again)
        if Date().timeIntervalSince(lastAsked) > Self.contextExpiry, !messages.isEmpty {
            messages = []
        }
        lastAsked = Date()
        messages.append(Message(role: .user, text: question))
        messages.append(Message(role: .model, text: ""))
        failure = nil
        isAsking = true
        let history = Array(messages.dropLast(2).suffix(Self.contextLimit))
        generation += 1
        let generation = generation

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await LLMClient.shared.ask(
                    question,
                    history: history.map { ($0.role == .user ? "user" : "assistant", $0.text) },
                    provider: provider,
                    model: AppSettings.shared.llmModel
                ) { [weak self] delta in
                    guard let self, generation == self.generation,
                          var last = messages.last, last.role == .model
                    else { return }
                    last.text += delta
                    messages[messages.count - 1] = last
                }
                guard generation == self.generation else { return }
                finish()
            } catch is CancellationError {
                guard generation == self.generation else { return }
                finish()
            } catch {
                guard generation == self.generation else { return }
                failure = error.localizedDescription
                // Don't leave an empty answer in history — it would only be in the way
                if messages.last?.text.isEmpty == true { messages.removeLast() }
                isAsking = false
                persist()
            }
        }
    }

    private func finish() {
        isAsking = false
        if messages.last?.text.isEmpty == true {
            messages.removeLast()
            failure = failure ?? String(localized: "The model didn't answer — try another one")
        }
        persist()
    }

    func cancel() {
        task?.cancel()
        task = nil
        // Bump the generation right away: anything still arriving from the
        // cancelled request belongs to the old question and shouldn't land
        // in the new bubble
        generation += 1
        isAsking = false
        // Clean up here, not in the task: its completion handlers are gated on
        // the generation we just invalidated and will never run. Without this,
        // an answer that hadn't started streaming stayed as an eternal
        // "thinking" bubble and rode along as context for the next question
        if let last = messages.last, last.role == .model, last.text.isEmpty {
            messages.removeLast()
        }
        persist()
    }

    /// New chat: context resets, so does the token bill
    func newChat() {
        cancel()
        messages = []
        failure = nil
        persist()
    }

    func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    private func persist() {
        // Only the stored copy is trimmed. Trimming `messages` itself cut the
        // beginning off a conversation that was open on screen
        let kept = Array(messages.suffix(Self.keepLimit))
        guard let data = try? JSONEncoder().encode(kept) else { return }
        store.set(data, forKey: key)
    }
}
