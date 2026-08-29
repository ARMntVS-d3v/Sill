import Foundation

// Model client. User's own key, choice of provider, streamed response — without
// streaming, the bar would look frozen for the several seconds the model thinks.
//
// We don't bundle a VPN and won't: plain HTTPS only. VPN on the Mac — it works;
// VPN off — we say plainly that the provider is unreachable.
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openRouter, anthropic, openAI, ollama

    var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .ollama: String(localized: "Ollama (local)")
        }
    }

    /// Ollama runs on the machine itself — no key needed
    var needsKey: Bool { self != .ollama }

    var defaultModel: String {
        switch self {
        case .openRouter: "anthropic/claude-3.5-sonnet"
        case .anthropic: "claude-sonnet-4-20250514"
        case .openAI: "gpt-4o-mini"
        case .ollama: "llama3.2"
        }
    }

    /// Where the model list comes from
    var modelsEndpoint: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/models")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/models")!
        case .openAI: URL(string: "https://api.openai.com/v1/models")!
        case .ollama: URL(string: "http://127.0.0.1:11434/api/tags")!
        }
    }

    var endpoint: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .ollama: URL(string: "http://127.0.0.1:11434/api/chat")!
        }
    }

    /// What to suggest when the provider stays silent
    var hint: String {
        switch self {
        case .openRouter, .anthropic, .openAI:
            String(localized: "You may need a VPN. Or switch to Ollama — it works without a network")
        case .ollama:
            String(localized: "Ollama isn't responding on 127.0.0.1:11434 — is it running?")
        }
    }
}

enum LLMError: LocalizedError {
    case noKey
    case unreachable(String)
    case badAnswer(Int)
    case emptyAnswer(String)

    var errorDescription: String? {
        switch self {
        case .noKey: String(localized: "No key set — Settings, \"Model\" section")
        case .unreachable(let hint): hint
        case .badAnswer(let code):
            code == 402 ? String(localized: "Provider is out of credits")
                : (code == 429 ? String(localized: "Too many requests — free models have a tight rate limit")
                   : String(localized: "Provider returned an error \(code)"))
        case .emptyAnswer(let body):
            body.isEmpty ? String(localized: "The model didn't answer") : String(localized: "Unexpected response: \(body)")
        }
    }
}

@MainActor @Observable
final class LLMClient {
    static let shared = LLMClient()

    /// Short system prompt: the answer needs to fit in a tile, not a dissertation
    private static let system = """
        Reply in the same language the user writes in, briefly and to the point, \
        with no preamble and no repeating the question. Keep the answer to a few \
        sentences unless asked for more detail.
        """

    @ObservationIgnored private let secrets = SecretsStore(widgetID: "llm")

    /// Whether a key is set. Three states, not two: until the Keychain has been
    /// asked, the answer is unknown. Two states weren't enough — the check runs
    /// in the background, and the panel would render "Key needed" only to have
    /// it change to "Ask" a fraction of a second later. Unknown is treated as
    /// "key present": scaring someone who has a key is worse than staying quiet
    /// for a second with someone who doesn't
    private(set) var hasKey: Bool?
    @ObservationIgnored private var keyChecked = false

    private init() {}

    /// One key per provider, not one for the app: settings show a "Key" field
    /// for each provider, and a single Keychain record meant entering the
    /// Anthropic key silently wiped the OpenRouter one
    nonisolated private static func account(for provider: LLMProvider) -> String {
        "apiKey.\(provider.rawValue)"
    }
    /// Pre-provider-split record; migrated to the current provider at launch
    nonisolated private static let legacyAccount = "apiKey"

    /// One-time "is there a key" check: asked off the main thread. Deferring it
    /// to the next run-loop pass isn't enough — the Keychain blocks whichever
    /// thread asked it, and the panel would freeze along with it.
    /// Checked once at launch, not when the panel opens: by the time it first
    /// shows, the answer is already there, and the bar's label doesn't flip
    /// live in front of you
    func checkKeyPresence() {
        guard !keyChecked else { return }
        keyChecked = true
        let provider = AppSettings.shared.llmProvider
        Task { [weak self] in
            guard let self else { return }
            let value = await migratedKey(for: provider)
            hasKey = !(value ?? "").isEmpty
        }
    }

    /// Migrate the pre-split key to the provider it was working with — the one
    /// selected in settings. The legacy record is deleted only after the copy
    /// is confirmed by reading it back: a failed write must not lose the key
    nonisolated private func migratedKey(for provider: LLMProvider) async -> String? {
        let account = Self.account(for: provider)
        if let existing = secrets.get(account) {
            return existing
        }
        guard let legacy = secrets.get(Self.legacyAccount), !legacy.isEmpty else { return nil }
        secrets.set(account, legacy)
        if secrets.get(account) == legacy {
            secrets.delete(Self.legacyAccount)
        }
        return legacy
    }

    /// Key or provider changed in settings — the flag needs to see it.
    /// Re-read off the main thread, same as the launch check
    func keyDidChange() {
        keyChecked = true
        let provider = AppSettings.shared.llmProvider
        Task { [weak self] in
            guard let self else { return }
            let value = await keyValue(for: provider)
            hasKey = !(value ?? "").isEmpty
        }
    }

    /// All Keychain access is async and off the main actor: a synchronous read
    /// can pop a password prompt and hold the calling thread — measured at
    /// 12.7 s of frozen main thread once already
    nonisolated func keyValue(for provider: LLMProvider) async -> String? {
        secrets.get(Self.account(for: provider))
    }

    nonisolated func storeKey(_ value: String?, for provider: LLMProvider) async {
        if let value, !value.isEmpty {
            secrets.set(Self.account(for: provider), value)
        } else {
            secrets.remove(Self.account(for: provider))
        }
    }

    /// Ask, and receive the answer in chunks as it's generated
    func ask(
        _ question: String,
        history: [(role: String, text: String)] = [],
        provider: LLMProvider,
        model: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws {
        let key = provider.needsKey ? await keyValue(for: provider) : nil
        let request = try buildRequest(
            question, history: history, provider: provider, model: model, key: key)
        let session = URLSession(configuration: .ephemeral)

        let (stream, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (stream, response) = try await session.bytes(for: request)
        } catch {
            throw LLMError.unreachable(provider.hint)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // 402 and 429 have dedicated human texts — the raw body must not
            // preempt them with "Unexpected response: Provider error: …"
            if http.statusCode == 402 || http.statusCode == 429 {
                throw LLMError.badAnswer(http.statusCode)
            }
            // The error body usually says exactly what went wrong
            var body = ""
            for try await line in stream.lines { body += line }
            if let text = Self.whole(body, provider: provider), text.hasPrefix("Provider error") {
                throw LLMError.emptyAnswer(text)
            }
            throw LLMError.badAnswer(http.statusCode)
        }

        var got = false
        var raw = ""
        do {
            for try await line in stream.lines {
                raw += line
                if let text = Self.delta(from: line, provider: provider) {
                    got = true
                    onDelta(text)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A drop mid-stream is the same "provider unreachable" as a failed
            // connect — the VPN/Ollama hint used to be lost past the headers
            throw LLMError.unreachable(provider.hint)
        }
        guard !got else { return }

        // No stream happened: some OpenRouter models ignore `stream` and return
        // plain JSON in one shot. This used to look like "asked, spun, nothing
        // arrived" — the bar silently went back to its idle state
        if let text = Self.whole(raw, provider: provider), !text.isEmpty {
            onDelta(text)
            return
        }
        throw LLMError.emptyAnswer(String(raw.prefix(200)))
    }

    /// The answer in one piece, not streamed
    nonisolated static func whole(_ body: String, provider: LLMProvider) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // The provider may have answered with an error in the body — show that too
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return "Provider error: \(message)"
        }
        switch provider {
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        case .ollama:
            return (json["message"] as? [String: Any])?["content"] as? String
        default:
            let choices = json["choices"] as? [[String: Any]] ?? []
            return (choices.first?["message"] as? [String: Any])?["content"] as? String
        }
    }

    struct Model: Identifiable, Sendable, Equatable {
        let id: String
        /// Whether it's free: for OpenRouter this is visible from the prices in the list itself
        let free: Bool
    }

    /// Models available with this key. Each provider has its own list, so we ask
    /// the provider directly instead of hardcoding a list that would go stale
    func models(provider: LLMProvider) async throws -> [Model] {
        var request = URLRequest(url: provider.modelsEndpoint)
        request.timeoutInterval = 15
        if provider.needsKey {
            guard let key = await keyValue(for: provider), !key.isEmpty else { throw LLMError.noKey }
            switch provider {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        let session = URLSession(configuration: .ephemeral)
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw LLMError.unreachable(provider.hint)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if provider == .ollama {
            let models = json["models"] as? [[String: Any]] ?? []
            // Local models are all free by definition
            return models.compactMap { $0["name"] as? String }.sorted().map { Model(id: $0, free: true) }
        }
        let models = json["data"] as? [[String: Any]] ?? []
        return models.compactMap { item -> Model? in
            guard let id = item["id"] as? String else { return nil }
            return Model(id: id, free: Self.isFree(item))
        }
        .sorted { ($0.free ? 0 : 1, $0.id) < ($1.free ? 0 : 1, $1.id) }
    }

    /// Considered free when both prices are zero. OpenRouter puts prices right
    /// in the model list; other providers don't have this field at all, so we
    /// treat those as paid
    private nonisolated static func isFree(_ item: [String: Any]) -> Bool {
        guard let pricing = item["pricing"] as? [String: Any] else { return false }
        let numbers = ["prompt", "completion"].compactMap { key -> Double? in
            if let text = pricing[key] as? String { return Double(text) }
            return pricing[key] as? Double
        }
        return numbers.count == 2 && numbers.allSatisfy { $0 == 0 }
    }

    // MARK: - request

    private func buildRequest(
        _ question: String,
        history: [(role: String, text: String)],
        provider: LLMProvider,
        model: String,
        key: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if provider.needsKey {
            guard let key, !key.isEmpty else { throw LLMError.noKey }
            switch provider {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        if provider == .openRouter {
            // OpenRouter asks apps to identify themselves via these headers
            request.setValue("https://github.com/sill", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Sill", forHTTPHeaderField: "X-Title")
        }

        // Conversation history rides along with the question — otherwise every
        // message starts a fresh chat and the model doesn't remember what was
        // just said
        let past = history.map { ["role": $0.role, "content": $0.text] }
        let body: [String: Any] = switch provider {
        case .anthropic:
            [
                "model": model,
                "max_tokens": 1024,
                "stream": true,
                "system": Self.system,
                "messages": past + [["role": "user", "content": question]],
            ]
        default:
            [
                "model": model,
                "stream": true,
                "messages": [["role": "system", "content": Self.system]] + past
                    + [["role": "user", "content": question]],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - stream parsing

    /// Extract a chunk of text from a stream line. OpenAI-compatible and
    /// Anthropic use SSE ("data: {…}"), Ollama is plain JSON per line
    nonisolated static func delta(from line: String, provider: LLMProvider) -> String? {
        var payload = line
        if provider != .ollama {
            guard line.hasPrefix("data: ") else { return nil }
            payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { return nil }
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        switch provider {
        case .anthropic:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any]
            else { return nil }
            return delta["text"] as? String
        case .ollama:
            guard let message = json["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        default:
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { return nil }
            return delta["content"] as? String
        }
    }
}
