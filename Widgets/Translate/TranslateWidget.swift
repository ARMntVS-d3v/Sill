import AppKit
import SwiftUI
import Translation

// Translator built on the system Translation framework: works offline, needs
// no keys or subscriptions, and the system downloads its own language packs.
//
// Programmatic access (not the popover, but a custom UI) arrived in macOS 15:
// `translationTask(configuration)` hands out a session with `translate(_:)`.
@MainActor @Observable
final class TranslateWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "translate",
        name: "Translator",
        icon: "character.bubble",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    /// A language pair. The source could be "auto" — then the system detects the
    /// language, and after translating we show what it detected
    struct Pair: Codable, Sendable, Equatable {
        /// Both languages are picked by the user. No auto-detection: guessing the
        /// language of what's being typed is one more source of errors, and on an
        /// uncertain guess the system used to pop up its own language-picker modal
        var source: String
        var target: String

        static let `default` = Pair(source: "ru", target: "en")

        /// Older settings stored `source: nil` ("Auto")
        init(source: String?, target: String) {
            self.source = source ?? Self.default.source
            self.target = target
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                source: try container.decodeIfPresent(String.self, forKey: .source),
                target: try container.decode(String.self, forKey: .target))
        }
    }


    private let context: WidgetContext

    var input: String {
        didSet {
            guard input != oldValue else { return }
            context.settings.set("input", input)
        }
    }
    private(set) var output = ""
    private(set) var isTranslating = false
    private(set) var failure: String?
    private(set) var pair: Pair

    init(context: WidgetContext) {
        self.context = context
        input = context.settings.get("input", as: String.self) ?? ""
        pair = context.settings.get("pair", as: Pair.self) ?? .default
        output = context.settings.get("output", as: String.self) ?? ""
    }

    var body: AnyView {
        AnyView(TranslateTileView(widget: self, size: context.tileSize))
    }

    /// Tapping the tile opens nothing: the whole translator lives here

    // MARK: - languages

    /// What the switcher shows: the language name on each side
    var sourceTitle: String { Self.title(of: pair.source) }

    var targetTitle: String { Self.title(of: pair.target) }

    /// Short labels for the square size: "RU", "EN". Full names don't fit —
    /// the header would grow wider than the tile, dragging the rest of the
    /// content with it and clipping the translated text at the edge
    var sourceShort: String { pair.source.uppercased() }

    var targetShort: String { pair.target.uppercased() }

    /// Languages the system actually supports. The list comes from the system
    /// itself — keeping our own would drift out of sync with the next macOS
    private(set) var languages: [String] = []

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        let codes = await Self.supportedCodes()
        languages = Array(Set(codes)).sorted { Self.title(of: $0) < Self.title(of: $1) }
    }

    /// The list is fetched off the main actor: `LanguageAvailability` isn't
    /// Sendable, and an object created on the main actor can't cross an await.
    /// Only plain string codes are returned outward
    private nonisolated static func supportedCodes() async -> [String] {
        await LanguageAvailability().supportedLanguages
            .map { $0.languageCode?.identifier ?? $0.minimalIdentifier }
    }

    static func title(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    /// Picking the language the other side already holds swaps the two: translating
    /// RU → RU is not a state anyone wants, and refusing the choice silently would
    /// look broken
    func setSource(_ code: String) {
        guard code != pair.source else { return }
        if code == pair.target { pair.target = pair.source }
        pair.source = code
        persistPair()
        retranslate()
    }

    func setTarget(_ code: String) {
        guard code != pair.target else { return }
        if code == pair.source { pair.source = pair.target }
        pair.target = code
        persistPair()
        retranslate()
    }

    /// Swap the two languages
    func swap() {
        let source = pair.source
        pair.source = pair.target
        pair.target = source
        persistPair()
        retranslate()
    }

    private func persistPair() { context.settings.set("pair", pair) }

    // MARK: - translation

    /// Request counter: the text may change while the session is still answering —
    /// a stale response is never written into the field
    @ObservationIgnored private var generation = 0
    /// What to translate on the session's next pass
    @ObservationIgnored private(set) var pendingText = ""

    /// The pair has no language pack on disk. The tile turns this into a button:
    /// leaving "No RU → EN pack" as plain text is a dead end
    private(set) var packMissing = false
    /// A download was asked for: the session is needed even with nothing to translate
    private var wantsDownload = false

    /// Show the system's language-download window. Only ever from a press — the rule
    /// is that the system window never pops up on its own while someone is typing
    func downloadPack() {
        wantsDownload = true
    }

    var configuration: TranslationSession.Configuration? {
        guard !pendingText.isEmpty || wantsDownload else { return nil }
        // Both languages are always explicit. With `source: nil` the system
        // translator guesses on its own and, when unsure, pops up its own modal
        // over the panel asking which language to translate from — mid-typing
        // and out of place
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target))
    }




    /// What we've already asked the system: "ru-en" -> installed or not. No need
    /// to ask on every keystroke — packs don't uninstall themselves
    @ObservationIgnored private var packCache: [String: Bool] = [:]

    /// Whether the pair's language pack is installed. Checked BEFORE requesting a
    /// translation: asking the session for a pair that isn't on disk makes the
    /// system pop up its own language-download window over the panel — mid-typing
    private nonisolated static func installed(_ source: String, _ target: String) async -> Bool {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target))
        return status == .installed
    }

    /// Translate this instant, without waiting out the debounce: Return in the field
    func translateNow() { retranslate(immediate: true) }

    /// Text changed — ask the session to translate again
    func retranslate(immediate: Bool = false) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        guard !text.isEmpty else {
            pendingText = ""
            output = ""
            failure = nil
            isTranslating = false
            context.settings.set("output", "")
            return
        }
        isTranslating = true
        failure = nil
        packMissing = false
        let mark = generation
        let key = "\(pair.source)-\(pair.target)"
        if let ready = packCache[key] {
            applyReadiness(ready, text: text, mark: mark, immediate: immediate)
            return
        }
        let pair = pair
        Task { [weak self] in
            let ready = await Self.installed(pair.source, pair.target)
            guard let self, mark == generation else { return }
            packCache[key] = ready
            applyReadiness(ready, text: text, mark: mark, immediate: immediate)
        }
    }

    /// Pack is there — enable the session (that's the translation). Not there —
    /// leave the session alone entirely and fall back to the model
    private func applyReadiness(_ ready: Bool, text: String, mark: Int, immediate: Bool) {
        guard mark == generation else { return }
        guard ready else {
            // No pack — never go to the session, or the system pops up its own
            // language-download window over the panel. Fall back to the model
            pendingText = ""
            context.log("pack \(pair.source)→\(pair.target) not installed")
            // Offer the download as soon as we know it's missing, not only when the
            // model fails: the model path is a network round trip per phrase, while
            // an installed pack translates locally and instantly. Without this the
            // person never learned the fast path existed
            packMissing = true
            translateByModel(text, mark: mark, immediate: immediate)
            return
        }
        pendingText = text
    }

    /// In-flight model request: cancelled the moment a newer one starts.
    /// Before this, every keystroke fired a full network request and none were
    /// cancelled — the answer waited in line behind all the stale ones
    @ObservationIgnored private var modelTask: Task<Void, Never>?

    /// What the model has already translated: same phrase, same pair — same answer.
    /// Retyping a word, switching tile sizes or reopening the panel used to buy a
    /// fresh round trip every time
    @ObservationIgnored private var modelCache: [String: String] = [:]

    private func cacheKey(_ text: String) -> String { "\(pair.source)-\(pair.target)-\(text)" }

    private func translateByModel(_ text: String, mark: Int, immediate: Bool = false) {
        if let cached = modelCache[cacheKey(text)] {
            isTranslating = false
            apply(cached)
            return
        }
        modelTask?.cancel()
        modelTask = Task { [weak self] in
            // Debounce: a model round-trip per keystroke is pure waste — wait for
            // the typing to pause. Short, because this path is already the slow one;
            // Return translates without waiting at all. The system path has no
            // debounce: it's local and effectively free
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            await self?.translateWithModel(text, mark: mark)
            guard let self, mark == generation else { return }
            isTranslating = false
            if output.isEmpty {
                failure = String(localized: "No \(pair.source.uppercased()) → \(pair.target.uppercased()) pack")
                packMissing = true
            }
        }
    }


    /// The session is handed out by SwiftUI: the system translator has no
    /// standalone object — it lives alongside the view
    func run(_ session: TranslationBox) async {
        if wantsDownload {
            wantsDownload = false
            do {
                try await Self.prepare(with: session)
                // Ask the system again: the pack may be there now
                packCache["\(pair.source)-\(pair.target)"] = nil
                packMissing = false
                retranslate()
            } catch {
                context.log("pack download failed: \(error)")
            }
            return
        }
        let text = pendingText
        guard !text.isEmpty else { return }
        let mark = generation
        do {
            let response = try await Self.translate(text, with: session)
            guard mark == generation else { return }
            // System returned the text unchanged — the pair's pack isn't
            // downloaded. It throws no error for this, so without this check the
            // widget would show the user their own text back as a "translation"
            if response.text == text, pair.source != pair.target {
                context.log("pack \(pair.source)→\(pair.target) not installed")
                await translateWithModel(text, mark: mark)
                if output.isEmpty || output == text {
                    failure = String(localized: "No \(pair.source.uppercased()) → \(pair.target.uppercased()) pack: system returned the text untranslated")
                    packMissing = true
                }
            } else {
                apply(response.text)
            }
        } catch {
            guard mark == generation else { return }
            context.log("session failed: \(error)")
            // System translator failed — try the model instead, if a key is set
            await translateWithModel(text, mark: mark)
        }
        isTranslating = false
    }

    /// The actual translation runs off the main actor and hands back only plain
    /// strings. Neither the session nor its response is marked Sendable: Swift 6
    /// won't let them cross back to the main actor, and the session can't live
    /// there either — its `translate` is a plain async method that runs on the
    /// shared executor

    /// The system's own download window for the pair. Same isolation dance as
    /// `translate`: the session can't cross back to the main actor
    private nonisolated static func prepare(with box: TranslationBox) async throws {
        try await box.session.prepareTranslation()
    }

    private nonisolated static func translate(
        _ text: String, with box: TranslationBox
    ) async throws -> (text: String, language: String?) {
        let response = try await box.session.translate(text)
        return (response.targetText, response.sourceLanguage.languageCode?.identifier)
    }

    private func apply(_ text: String) {
        output = text
        failure = nil
        context.settings.set("output", text)
    }

    /// Fallback path: the system may not have this language pair, or the pack
    /// isn't downloaded. The model translates instead — the app already has one
    private func translateWithModel(_ text: String, mark: Int) async {
        // `nil` means the keychain hasn't been checked yet: try anyway, the request itself will surface any error
        guard LLMClient.shared.hasKey != false || AppSettings.shared.llmProvider == .ollama else {
            failure = String(localized: "The system couldn't translate")
            return
        }
        let target = Self.title(of: pair.target)
        let started = Date()
        do {
            var collected = ""
            try await LLMClient.shared.ask(
                "Translate into \(target). Return only the translation, no explanations:\n\(text)",
                provider: AppSettings.shared.llmProvider,
                model: AppSettings.shared.llmModel
            ) { [weak self] delta in
                collected += delta
                // Stream into the tile as it arrives: waiting for the full
                // answer made the model path feel twice as slow as it is
                guard let self, mark == generation else { return }
                output = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard mark == generation else { return }
            let answer = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                // Bounded: a tile shouldn't grow a dictionary of everything ever typed
                if modelCache.count > 40 { modelCache.removeAll() }
                modelCache[cacheKey(text)] = answer
            }
            context.log("model answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            apply(answer)
        } catch is CancellationError {
        } catch {
            guard mark == generation else { return }
            failure = String(localized: "Translation failed")
        }
    }


    // MARK: - clipboard


    func copyResult() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    func clear() {
        input = ""
        retranslate()
    }

    var isEmpty: Bool { input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The translation session lives alongside the view and isn't marked Sendable,
/// yet it translates via a plain async method — i.e. on the shared executor.
/// Under Swift 6 that counts as sending the object off the main actor, which
/// won't compile. This wrapper takes responsibility for that: SwiftUI creates
/// the session for this one task, only this code touches it, and the object
/// never passes into other hands
struct TranslationBox: @unchecked Sendable {
    let session: TranslationSession
}
