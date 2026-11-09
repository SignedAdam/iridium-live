import Foundation

struct SavedModel: Codable, Hashable, Identifiable {
    var modelID: String
    var modelName: String
    var providerName: String
    var tag: String

    var id: String { "\(modelID)@\(tag)" }

    var shortName: String {
        modelName.range(of: ": ").map { String(modelName[$0.upperBound...]) } ?? modelName
    }

    var title: String { "\(shortName) on \(providerName)" }

    static let starters = [
        SavedModel(modelID: "qwen/qwen3.8-27b", modelName: "Qwen: Qwen3.8 27B", providerName: "Cerebras", tag: "cerebras/fp16"),
        SavedModel(modelID: "deepseek/deepseek-v4.1-flash", modelName: "DeepSeek: DeepSeek V4.1 Flash",
                   providerName: "BaseTen", tag: "baseten/fp8"),
        SavedModel(modelID: "nvidia/nemotron-3.5-lightning", modelName: "NVIDIA: Nemotron 3.5 Lightning",
                   providerName: "CoreWeave", tag: "coreweave/bf16"),
        SavedModel(modelID: "cohere/command-a-plus", modelName: "Cohere: Command A+", providerName: "Cohere", tag: "cohere"),
    ]
}

struct Settings: Codable, Equatable {
    enum CaptionPosition: String, Codable { case top, bottom }
    enum CleanupFailure: String, Codable { case retry, notify, raw }
    enum SpeechFallback: String, Codable { case local, fail }
    enum SpeechMode: String, Codable { case live, afterStop = "after-stop" }
    enum ApiProvider: String, Codable { case albastar, custom }

    var speechModel = "phonon-2"
    /// The API (Settings, Provider): Albastar, or any OpenAI-compatible base URL with its own key.
    var apiProvider = ApiProvider.albastar
    var apiCustomBase = ""
    var apiSpeechMode = SpeechMode.live
    var apiSpeechModels: [String: String] = [:] // per provider: the speech model id
    var apiSpeechTimeoutS = 8.0
    var apiFallback = SpeechFallback.local
    var typingHold = 0.7
    var pasteApps = ["so.stencil.tern"] // bundle IDs that get each sentence as one paste instead of typed keys
    var sounds = true
    var cleanupEnabled = false
    var cleanupProvider = "openrouter"
    var cleanupModels: [String: String] = [:]
    var cleanupInstructions = ""
    var cleanupPolish = true
    var cleanupBenchmark = false
    var cleanupCorrections = true
    var cleanupContextSentences = 5
    var cleanupEditReach = 2
    var cleanupQuotes = false
    var cleanupFailure = CleanupFailure.raw
    var cleanupRetries = 3
    var cleanupTimeoutS: [String: Double] = ["groq": 2.5, "openrouter": 2.5, "api": 4]
    var openRouterModels = SavedModel.starters
    var openRouterRecent = SavedModel.starters.map(\.id)
    var captionsShown = true
    var captionPosition = CaptionPosition.top
    var captionFont = "TikTok Sans"
    var captionSize = 48.0
    var captionSeconds = 4.0
    var captionOpacity = 1.0
    var glassTint = 0.0
    var controlOpacity = 0.95
    var hotkeys: [Hotkey] = []
    var saveAudio = false
    var autoUnload = false
    var autoUnloadMinutes = 30
    var controlHidden = false
    var controlHiddenUntil: Date? = nil
    var compactControl = false
    var meetingEngine = "apple.speechanalyzer"
    var meetingLanguage = "en-US"
    var meetingMic = true
    var meetingSystem = true
    var meetingMicrophone: String?
    var meetingAutoTranscribe = true
    var meetingLiveTranscript = true
    var summaryProvider = "openrouter"
    var summaryModels: [String: String] = [:]
    var notesFiling = true

    static let albastarBase = "https://api.albastov.com/v1"
    static let speechModels = [("phonon-2", "Phonon-2 · this Mac"), ("parakeet", "Parakeet · this Mac"),
                               ("api", "API · Provider above")]
    static let cleanupProviders: [(id: String, name: String, models: [(String, String)])] = [
        ("groq", "Groq", [("qwen/qwen3.8-27b", "Qwen3.8 27B"), ("openai/gpt-oss-120b", "GPT-OSS 120B"),
                          ("openai/gpt-oss-20b", "GPT-OSS 20B")]),
        ("openrouter", "OpenRouter", []),
        ("api", "API", []), // the provider of Settings, Provider; `auto` lets it pick the model
    ]
    static let meetingLanguages = [("en-US", "English (US)"), ("en-GB", "English (UK)"), ("sv-SE", "Swedish"),
                                   ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"),
                                   ("it-IT", "Italian"), ("nl-NL", "Dutch"), ("pt-BR", "Portuguese"),
                                   ("da-DK", "Danish"), ("nb-NO", "Norwegian"), ("fi-FI", "Finnish"),
                                   ("pl-PL", "Polish"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese")]
    static let summaryProviders: [(id: String, name: String, models: [(String, String)])] = [
        ("openrouter", "OpenRouter", []),
        ("anthropic", "Anthropic", [("claude-opus-4-8", "Claude Opus 4.8")]),
    ]
    static let captionFonts = ["TikTok Sans", "SF Pro", "SF Pro Rounded", "New York", "Menlo"]
    static let idleChoices = [(5, "5 min"), (15, "15 min"), (30, "30 min"), (60, "1 h"), (120, "2 h"), (360, "6 h")]

    func cleanupModels(on provider: String) -> [(String, String)] {
        guard provider == "openrouter" else { return Self.cleanupProviders.first { $0.id == provider }?.models ?? [] }
        return openRouterModels.map { ($0.id, $0.title) }
    }

    static func modelName(provider: String, model: String) -> String {
        if let name = cleanupProviders.first(where: { $0.id == provider })?.models.first(where: { $0.0 == model })?.1 {
            return name
        }
        let parts = model.split(separator: "@", maxSplits: 1).map(String.init)
        let name = parts[0].split(separator: "/").last.map(String.init) ?? parts[0]
        guard parts.count == 2, let host = parts[1].split(separator: "/").first else { return name }
        return "\(name) on \(host.prefix(1).uppercased())\(host.dropFirst())"
    }

    var cleanupModel: String {
        get {
            // an id from the API's GET /models, `auto` until one is picked
            if cleanupProvider == "api" { return cleanupModels[apiModelKey] ?? "auto" }
            let offered = cleanupModels(on: cleanupProvider)
            if let picked = cleanupModels[cleanupProvider], offered.contains(where: { $0.0 == picked }) { return picked }
            return cleanupProvider == "openrouter" ? (openRouterRecent.first ?? offered.first?.0 ?? "") : offered.first?.0 ?? ""
        }
        set { cleanupModels[cleanupProvider == "api" ? apiModelKey : cleanupProvider] = newValue }
    }

    func summaryModels(on provider: String) -> [(String, String)] {
        guard provider == "openrouter" else { return Self.summaryProviders.first { $0.id == provider }?.models ?? [] }
        return savedModelsByRecency.map { ($0.id, $0.title) }
    }

    var summaryModel: String {
        get {
            let offered = summaryModels(on: summaryProvider)
            if let picked = summaryModels[summaryProvider], offered.contains(where: { $0.0 == picked }) { return picked }
            if summaryProvider == "openrouter" {
                if let cleanup = cleanupModels["openrouter"], !cleanup.isEmpty { return cleanup }
                return openRouterRecent.first ?? offered.first?.0 ?? ""
            }
            return offered.first?.0 ?? ""
        }
        set { summaryModels[summaryProvider] = newValue }
    }

    var summaryKey: String { summaryProvider == "anthropic" ? "anthropic" : "openrouter" }

    var savedModelsByRecency: [SavedModel] {
        let order = Dictionary(uniqueKeysWithValues: openRouterRecent.enumerated().map { ($1, $0) })
        return openRouterModels.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    var cleanupCommand: String {
        guard cleanupEnabled else { return "cleanup off" }
        return "cleanup \(cleanupProvider):\(cleanupModel)"
    }

    var correctionsCommand: String {
        cleanupCorrections ? "corrections \(cleanupContextSentences) \(min(cleanupEditReach, cleanupContextSentences))"
                           : "corrections off"
    }

    var rulesCommand: String {
        "rules " + (cleanupQuotes ? ["quotes"] : []).joined(separator: ",")
    }

    var failureCommand: String {
        "failure \(cleanupFailure.rawValue) \(cleanupRetries)"
    }

    var cleanupTimeoutCommand: String {
        "timeout \(cleanupTimeoutS[cleanupProvider] ?? 2.5)"
    }

    /// The cleanup model chosen per provider preset: the custom provider's models are not ours.
    private var apiModelKey: String { "api-\(apiProvider.rawValue)" }

    var apiBase: String {
        switch apiProvider {
        case .albastar: Self.albastarBase
        case .custom:
            String(apiCustomBase.trimmingCharacters(in: .whitespacesAndNewlines).reversed().drop { $0 == "/" }.reversed())
        }
    }

    var apiKey: ApiKey { apiProvider == .albastar ? .citadel : .custom }

    /// The key the cleanup provider is called with: the API provider's own, else the one named after the provider.
    var cleanupKey: ApiKey { cleanupProvider == "api" ? apiKey : ApiKey.named(cleanupProvider) ?? .openRouter }

    /// How the status line names the provider: Albastar, or the custom base URL's host.
    var apiName: String {
        apiProvider == .albastar ? "Albastar" : URL(string: apiBase)?.host() ?? "Custom API"
    }

    var apiSpeechModel: String {
        get { apiSpeechModels[apiProvider.rawValue] ?? (apiProvider == .albastar ? "parakeet" : "") }
        set { apiSpeechModels[apiProvider.rawValue] = newValue }
    }

    /// The engine's name for the speech model: the API one depends on the mode.
    var speechEngine: String {
        guard speechModel == "api" else { return speechModel }
        return apiSpeechMode == .live ? "api-live" : "api"
    }

    var apiCommand: String {
        let config: [String: Any] = ["base": apiBase, "key_env": apiKey.variable, "name": apiName,
                                     "model": apiSpeechModel, "timeout_s": apiSpeechTimeoutS,
                                     "fallback": apiFallback.rawValue]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data("{}".utf8)
        return "api " + String(decoding: data, as: UTF8.self)
    }

    static func knows(_ key: String) -> Bool { CodingKeys(stringValue: key) != nil }
}

extension Settings {
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKey.self)
        let fallback = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? saved.decodeIfPresent(T.self, forKey: key)) ?? current }
        func old<T: Decodable>(_ name: String) -> T? { try? legacy.decodeIfPresent(T.self, forKey: LegacyKey(name)) }
        // Vegeta became the API at Albastar, after stop over HTTP or live over Vegeta Live; its settings carry over
        let speech = value(.speechModel, fallback.speechModel)
        speechModel = speech == "vegeta" || speech == "vegeta-live" ? "api" : speech
        apiProvider = value(.apiProvider, fallback.apiProvider)
        apiCustomBase = value(.apiCustomBase, fallback.apiCustomBase)
        apiSpeechMode = value(.apiSpeechMode, speech == "vegeta" ? .afterStop : fallback.apiSpeechMode)
        apiSpeechModels = value(.apiSpeechModels, (old("vegetaSpeechModel") as String?).map { ["albastar": $0] }
                                ?? fallback.apiSpeechModels)
        apiSpeechTimeoutS = value(.apiSpeechTimeoutS, old("vegetaSpeechTimeoutS") ?? fallback.apiSpeechTimeoutS)
        apiFallback = value(.apiFallback, old("vegetaFallback") ?? fallback.apiFallback)
        typingHold = value(.typingHold, fallback.typingHold)
        pasteApps = value(.pasteApps, fallback.pasteApps)
        sounds = value(.sounds, fallback.sounds)
        cleanupEnabled = value(.cleanupEnabled, fallback.cleanupEnabled)
        let provider = value(.cleanupProvider, fallback.cleanupProvider)
        let migrated = provider == "vegeta" || provider == "vegeta-live" ? "api" : provider
        cleanupProvider = Settings.cleanupProviders.contains { $0.id == migrated } ? migrated : fallback.cleanupProvider
        cleanupInstructions = value(.cleanupInstructions, fallback.cleanupInstructions)
        cleanupPolish = value(.cleanupPolish, fallback.cleanupPolish)
        cleanupBenchmark = value(.cleanupBenchmark, fallback.cleanupBenchmark)
        cleanupCorrections = value(.cleanupCorrections, fallback.cleanupCorrections)
        cleanupContextSentences = value(.cleanupContextSentences, fallback.cleanupContextSentences)
        cleanupEditReach = value(.cleanupEditReach, fallback.cleanupEditReach)
        cleanupQuotes = value(.cleanupQuotes, fallback.cleanupQuotes)
        cleanupFailure = value(.cleanupFailure, fallback.cleanupFailure)
        cleanupRetries = value(.cleanupRetries, fallback.cleanupRetries)
        cleanupTimeoutS = value(.cleanupTimeoutS, fallback.cleanupTimeoutS)
        if cleanupTimeoutS["api"] == nil { cleanupTimeoutS["api"] = cleanupTimeoutS["vegeta"] ?? 4 }
        openRouterModels = value(.openRouterModels, fallback.openRouterModels)
        openRouterRecent = value(.openRouterRecent, fallback.openRouterRecent)
        captionsShown = value(.captionsShown, fallback.captionsShown)
        captionPosition = value(.captionPosition, fallback.captionPosition)
        captionFont = value(.captionFont, fallback.captionFont)
        captionSize = value(.captionSize, fallback.captionSize)
        captionSeconds = value(.captionSeconds, fallback.captionSeconds)
        captionOpacity = value(.captionOpacity, fallback.captionOpacity)
        glassTint = value(.glassTint, fallback.glassTint)
        controlOpacity = value(.controlOpacity, fallback.controlOpacity)
        hotkeys = value(.hotkeys, SavedHotkeys(hotkeys: fallback.hotkeys)).hotkeys
        saveAudio = value(.saveAudio, fallback.saveAudio)
        autoUnload = value(.autoUnload, fallback.autoUnload)
        autoUnloadMinutes = value(.autoUnloadMinutes, fallback.autoUnloadMinutes)
        controlHidden = value(.controlHidden, fallback.controlHidden)
        controlHiddenUntil = value(.controlHiddenUntil, fallback.controlHiddenUntil)
        compactControl = value(.compactControl, fallback.compactControl)
        meetingEngine = value(.meetingEngine, fallback.meetingEngine)
        meetingLanguage = value(.meetingLanguage, fallback.meetingLanguage)
        meetingMic = value(.meetingMic, fallback.meetingMic)
        meetingSystem = value(.meetingSystem, fallback.meetingSystem)
        meetingMicrophone = (try? saved.decodeIfPresent(String.self, forKey: .meetingMicrophone)) ?? nil
        meetingAutoTranscribe = value(.meetingAutoTranscribe, fallback.meetingAutoTranscribe)
        meetingLiveTranscript = value(.meetingLiveTranscript, fallback.meetingLiveTranscript)
        let summary = value(.summaryProvider, fallback.summaryProvider)
        summaryProvider = Settings.summaryProviders.contains { $0.id == summary } ? summary : fallback.summaryProvider
        summaryModels = value(.summaryModels, fallback.summaryModels)
        notesFiling = value(.notesFiling, fallback.notesFiling)
    }

    /// Keys of earlier versions, read once to carry their values over.
    private struct LegacyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Settings live in `settings.json`, which may be edited while the app is closed: the app reads it at launch and
/// writes every change back, pretty-printed with sorted keys. Keys it does not know are kept. A file that does not
/// parse is left alone: the app runs on the last good settings (`settings.last-good.json`) and saves nothing until
/// the next launch. The very first launch writes the file from the settings the app kept in UserDefaults.
@MainActor
final class SettingsFile {
    static let shared = SettingsFile(directory: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                         in: .userDomainMask)[0]
        .appendingPathComponent("Iridium Live"))

    let url: URL
    private let lastGood: URL
    /// Why the file was not used; while set, nothing is written.
    private(set) var problem: String?
    private var unknown: [String: Any] = [:]

    init(directory: URL) {
        url = directory.appendingPathComponent("settings.json")
        lastGood = directory.appendingPathComponent("settings.last-good.json")
    }

    func load() -> Settings {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            let settings = UserDefaults.standard.data(forKey: "settings")
                .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
            save(settings)
            return settings
        }
        do {
            let settings = try decode(data)
            try? data.write(to: lastGood, options: .atomic)
            return settings
        } catch {
            problem = "settings.json has an error: using the last good settings"
            FileHandle.standardError.write(Data("\(url.path) did not parse, nothing is saved until it does: \(error)\n".utf8))
            return FileManager.default.contents(atPath: lastGood.path).flatMap { try? decode($0) } ?? Settings()
        }
    }

    func save(_ settings: Settings) {
        guard problem == nil else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(settings),
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
        object.merge(unknown) { known, _ in known }
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try data.write(to: lastGood, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
        }
    }

    private func decode(_ data: Data) throws -> Settings {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(Settings.self, from: data)
        unknown = object.filter { !Settings.knows($0.key) }
        return settings
    }
}

