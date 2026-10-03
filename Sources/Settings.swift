import Foundation

struct Settings: Codable, Equatable {
    enum CaptionPosition: String, Codable { case top, bottom }
    enum CleanupFailure: String, Codable { case retry, notify, raw }

    var speechModel = "phonon-2"
    var typingHold = 0.7
    var cleanupEnabled = false
    var cleanupProvider = "groq"
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

    static let speechModels = [("phonon-2", "Phonon-2"), ("parakeet", "Parakeet")]
    static let cleanupProviders: [(id: String, name: String, models: [(String, String)])] = [
        ("groq", "Groq", [("qwen/qwen3.8-27b", "Qwen3.8 27B"), ("openai/gpt-oss-120b", "GPT-OSS 120B"),
                          ("openai/gpt-oss-20b", "GPT-OSS 20B")]),
        ("openrouter", "OpenRouter", [("openai/gpt-oss-120b:nitro", "GPT-OSS 120B"), ("qwen/qwen3.8-27b:nitro", "Qwen3.8 27B"),
                                      ("inclusionai/ling-3.0-flash", "Ling 3.0 Flash")]),
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

    static func cleanupModels(on provider: String) -> [(String, String)] {
        cleanupProviders.first { $0.id == provider }?.models ?? []
    }

    var cleanupModel: String {
        get {
            let offered = Self.cleanupModels(on: cleanupProvider)
            if let picked = cleanupModels[cleanupProvider], offered.contains(where: { $0.0 == picked }) { return picked }
            return offered.first?.0 ?? ""
        }
        set { cleanupModels[cleanupProvider] = newValue }
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
    }
}

