import Foundation

/// Everything the user can set. Saved in the user defaults; values missing from an older save keep their defaults.
struct Settings: Codable, Equatable {
    enum CaptionPosition: String, Codable { case top, bottom }

    var speechModel = "phonon-2"
    var typingHold = 0.7
    var cleanupEnabled = false
    var cleanupProvider = "groq"
    var cleanupModels: [String: String] = [:]  // the model picked on each provider; none yet means its first
    var cleanupInstructions = ""                // the user's own rules for the cleanup model, added to its prompt
    var cleanupPolish = true                    // one more pass over the whole of a recording when it stops
    var cleanupBenchmark = false                // every other model of the provider answers each phrase as well
    var captionsShown = true
    var captionPosition = CaptionPosition.top
    var captionFont = "TikTok Sans"
    var captionSize = 48.0
    var captionSeconds = 4.0
    var captionOpacity = 1.0
    var glassTint = 0.0
    var controlOpacity = 1.0
    var hotkeys: [Hotkey] = []
    var saveAudio = false
    var audioSplitSeconds = 2.0
    var autoUnload = false
    var autoUnloadMinutes = 30

    static let speechModels = [("phonon-2", "Phonon-2"), ("parakeet", "Parakeet")]
    /// Where cleanup can run, each with its models, the default first (chosen by measured latency and accuracy on
    /// dictated phrases). Both are called over the network with `GROQ_API_KEY` / `OPENROUTER_API_KEY`, so cleanup
    /// costs this Mac no memory at all.
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

    /// The model cleanup uses on its current provider: the one picked there, while it is still offered, else the
    /// provider's default.
    var cleanupModel: String {
        get {
            let offered = Self.cleanupModels(on: cleanupProvider)
            if let picked = cleanupModels[cleanupProvider], offered.contains(where: { $0.0 == picked }) { return picked }
            return offered.first?.0 ?? ""
        }
        set { cleanupModels[cleanupProvider] = newValue }
    }

    /// The engine command for the cleanup as set: off, or `provider:model` at a provider.
    var cleanupCommand: String {
        guard cleanupEnabled else { return "cleanup off" }
        return "cleanup \(cleanupProvider):\(cleanupModel)"
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
        // Cleanup used to be able to run on this Mac; it no longer can, so a save that names a provider nobody
        // offers any more (and only that) comes back as the default. The models picked at the other providers stay.
        let provider = value(.cleanupProvider, fallback.cleanupProvider)
        cleanupProvider = Settings.cleanupProviders.contains { $0.id == provider } ? provider : fallback.cleanupProvider
        cleanupModels = value(.cleanupModels, fallback.cleanupModels)
        cleanupInstructions = value(.cleanupInstructions, fallback.cleanupInstructions)
        cleanupPolish = value(.cleanupPolish, fallback.cleanupPolish)
        cleanupBenchmark = value(.cleanupBenchmark, fallback.cleanupBenchmark)
        captionsShown = value(.captionsShown, fallback.captionsShown)
        captionPosition = value(.captionPosition, fallback.captionPosition)
        captionFont = value(.captionFont, fallback.captionFont)
        captionSize = value(.captionSize, fallback.captionSize)
        captionSeconds = value(.captionSeconds, fallback.captionSeconds)
        captionOpacity = value(.captionOpacity, fallback.captionOpacity)
        glassTint = value(.glassTint, fallback.glassTint)
        controlOpacity = value(.controlOpacity, fallback.controlOpacity)
        hotkeys = value(.hotkeys, SavedHotkeys(hotkeys: fallback.hotkeys)).hotkeys  // older saves carried a mode
        saveAudio = value(.saveAudio, fallback.saveAudio)
        audioSplitSeconds = value(.audioSplitSeconds, fallback.audioSplitSeconds)
        autoUnload = value(.autoUnload, fallback.autoUnload)
        autoUnloadMinutes = value(.autoUnloadMinutes, fallback.autoUnloadMinutes)
    }
}
