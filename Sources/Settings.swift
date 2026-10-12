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

    var speechModel = "phonon-2"
    var typingHold = 0.7
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
    var audioSplitSeconds = 2.0
    var autoUnload = false
    var autoUnloadMinutes = 30
    var controlHidden = false
    var meetingEngine = "apple.speechanalyzer"
    var meetingLanguage = "en-US"
    var meetingMic = true
    var meetingSystem = true
    var meetingMicrophone: String?
    var summaryProvider = "openrouter"
    var summaryModels: [String: String] = [:]

    static let speechModels = [("phonon-2", "Phonon-2"), ("parakeet", "Parakeet")]
    static let cleanupProviders: [(id: String, name: String, models: [(String, String)])] = [
        ("groq", "Groq", [("qwen/qwen3.8-27b", "Qwen3.8 27B"), ("openai/gpt-oss-120b", "GPT-OSS 120B"),
                          ("openai/gpt-oss-20b", "GPT-OSS 20B")]),
        ("openrouter", "OpenRouter", []),
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

    private static let key = "settings"

    static func load() -> Settings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

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
            let offered = cleanupModels(on: cleanupProvider)
            if let picked = cleanupModels[cleanupProvider], offered.contains(where: { $0.0 == picked }) { return picked }
            return cleanupProvider == "openrouter" ? (openRouterRecent.first ?? offered.first?.0 ?? "") : offered.first?.0 ?? ""
        }
        set { cleanupModels[cleanupProvider] = newValue }
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

    func failureCommand(folder: String) -> String {
        "failure \(cleanupFailure.rawValue) \(cleanupRetries) \(folder)"
    }
}

extension Settings {
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? saved.decodeIfPresent(T.self, forKey: key)) ?? current }
        speechModel = value(.speechModel, fallback.speechModel)
        typingHold = value(.typingHold, fallback.typingHold)
        cleanupEnabled = value(.cleanupEnabled, fallback.cleanupEnabled)
        let provider = value(.cleanupProvider, fallback.cleanupProvider)
        cleanupProvider = Settings.cleanupProviders.contains { $0.id == provider } ? provider : fallback.cleanupProvider
        cleanupModels = value(.cleanupModels, fallback.cleanupModels)
        cleanupInstructions = value(.cleanupInstructions, fallback.cleanupInstructions)
        cleanupPolish = value(.cleanupPolish, fallback.cleanupPolish)
        cleanupBenchmark = value(.cleanupBenchmark, fallback.cleanupBenchmark)
        cleanupCorrections = value(.cleanupCorrections, fallback.cleanupCorrections)
        cleanupContextSentences = value(.cleanupContextSentences, fallback.cleanupContextSentences)
        cleanupEditReach = value(.cleanupEditReach, fallback.cleanupEditReach)
        cleanupQuotes = value(.cleanupQuotes, fallback.cleanupQuotes)
        cleanupFailure = value(.cleanupFailure, fallback.cleanupFailure)
        cleanupRetries = value(.cleanupRetries, fallback.cleanupRetries)
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
        audioSplitSeconds = value(.audioSplitSeconds, fallback.audioSplitSeconds)
        autoUnload = value(.autoUnload, fallback.autoUnload)
        autoUnloadMinutes = value(.autoUnloadMinutes, fallback.autoUnloadMinutes)
        controlHidden = value(.controlHidden, fallback.controlHidden)
        meetingEngine = value(.meetingEngine, fallback.meetingEngine)
        meetingLanguage = value(.meetingLanguage, fallback.meetingLanguage)
        meetingMic = value(.meetingMic, fallback.meetingMic)
        meetingSystem = value(.meetingSystem, fallback.meetingSystem)
        meetingMicrophone = (try? saved.decodeIfPresent(String.self, forKey: .meetingMicrophone)) ?? nil
        let summary = value(.summaryProvider, fallback.summaryProvider)
        summaryProvider = Settings.summaryProviders.contains { $0.id == summary } ? summary : fallback.summaryProvider
        summaryModels = value(.summaryModels, fallback.summaryModels)
    }
}

