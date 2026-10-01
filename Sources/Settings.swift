import Foundation

/// Everything the user can set. Saved in the user defaults; values missing from an older save keep their defaults.
struct Settings: Codable, Equatable {
    enum CaptionPosition: String, Codable { case top, bottom }

    var speechModel = "phonon-2"
    var typingHold = 0.7
    var cleanupEnabled = false
    var cleanupProvider = "groq"
    var cleanupModels: [String: String] = [:]  // the model picked on each provider; none yet means its first
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

    static let speechModels = [("phonon-2", "Phonon-2"), ("parakeet", "Parakeet")]
    /// Where cleanup can run, each with its models, the default first (chosen by measured latency and accuracy on
    /// dictated phrases). Groq and OpenRouter are called over the network with `GROQ_API_KEY` / `OPENROUTER_API_KEY`;
    /// This Mac runs mlx-lm models, about 2.5 GB of memory while on.
    static let cleanupProviders: [(id: String, name: String, models: [(String, String)])] = [
        ("groq", "Groq", [("qwen/qwen3.8-27b", "Qwen3.8 27B"), ("openai/gpt-oss-120b", "GPT-OSS 120B"),
                          ("openai/gpt-oss-20b", "GPT-OSS 20B")]),
        ("openrouter", "OpenRouter", [("openai/gpt-oss-120b:nitro", "GPT-OSS 120B"), ("qwen/qwen3.8-27b:nitro", "Qwen3.8 27B"),
                                      ("inclusionai/ling-3.0-flash", "Ling 3.0 Flash")]),
        (localCleanup, "This Mac", [("qwen3-4b", "Qwen3 4B"), ("llama-3.2-3b", "Llama 3.2 3B")]),
    ]
    static let localCleanup = "local"
    static let captionFonts = ["TikTok Sans", "SF Pro", "SF Pro Rounded", "New York", "Menlo"]

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

    /// The engine command for the cleanup as set: off, a model on this Mac, or `provider:model` over the network.
    var cleanupCommand: String {
        guard cleanupEnabled else { return "cleanup off" }
        return cleanupProvider == Self.localCleanup ? "cleanup \(cleanupModel)" : "cleanup \(cleanupProvider):\(cleanupModel)"
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
        cleanupProvider = value(.cleanupProvider, fallback.cleanupProvider)
        cleanupModels = value(.cleanupModels, fallback.cleanupModels)
        captionsShown = value(.captionsShown, fallback.captionsShown)
        captionPosition = value(.captionPosition, fallback.captionPosition)
        captionFont = value(.captionFont, fallback.captionFont)
        captionSize = value(.captionSize, fallback.captionSize)
        captionSeconds = value(.captionSeconds, fallback.captionSeconds)
        captionOpacity = value(.captionOpacity, fallback.captionOpacity)
        glassTint = value(.glassTint, fallback.glassTint)
        controlOpacity = value(.controlOpacity, fallback.controlOpacity)
        hotkeys = value(.hotkeys, fallback.hotkeys)
        saveAudio = value(.saveAudio, fallback.saveAudio)
        audioSplitSeconds = value(.audioSplitSeconds, fallback.audioSplitSeconds)
    }
}
