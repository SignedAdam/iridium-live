import Foundation

/// Everything the user can set. Saved in the user defaults; values missing from an older save keep their defaults.
struct Settings: Codable, Equatable {
    enum CaptionPosition: String, Codable { case top, bottom }

    var speechModel = "phonon-2"
    var typingHold = 0.7
    var cleanupEnabled = false
    var cleanupModel = "qwen3-4b"
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
    static let cleanupModels = [("qwen3-4b", "Qwen3 4B"), ("llama-3.2-3b", "Llama 3.2 3B")]
    static let captionFonts = ["TikTok Sans", "SF Pro", "SF Pro Rounded", "New York", "Menlo"]

    private static let key = "settings"

    static func load() -> Settings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
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
        cleanupModel = value(.cleanupModel, fallback.cleanupModel)
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
