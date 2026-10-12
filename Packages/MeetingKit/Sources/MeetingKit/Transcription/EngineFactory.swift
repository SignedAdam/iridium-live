import Foundation

public struct EngineOption: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let key: String?
    public let diarizes: Bool
    public let local: Bool
}

public enum EngineFactory {
    public static let options: [EngineOption] = [
        EngineOption(id: EngineID.appleSpeechAnalyzer, name: "Apple", key: nil, diarizes: false, local: true),
        EngineOption(id: EngineID.parakeetLocal, name: "Parakeet", key: nil, diarizes: false, local: true),
        EngineOption(id: EngineID.elevenLabs, name: "ElevenLabs", key: "elevenlabs", diarizes: true, local: false),
        EngineOption(id: EngineID.assemblyAI, name: "AssemblyAI", key: "assemblyai", diarizes: true, local: false),
        EngineOption(id: EngineID.deepgram, name: "Deepgram", key: "deepgram", diarizes: true, local: false),
    ]

    public static func name(for id: String?) -> String {
        guard let id else { return "" }
        return options.first { $0.id == id }?.name ?? id
    }

    static func resolvedEngine(for config: MeetingConfig) -> TranscriptionEngine {
        switch config.engineID {
        case EngineID.elevenLabs:
            if let key = config.key("elevenlabs"), !key.isEmpty { return ElevenLabsEngine(apiKey: key) }
        case EngineID.assemblyAI:
            if let key = config.key("assemblyai"), !key.isEmpty { return AssemblyAIEngine(apiKey: key) }
        case EngineID.deepgram:
            if let key = config.key("deepgram"), !key.isEmpty { return DeepgramEngine(apiKey: key) }
        case EngineID.parakeetLocal:
            return ParakeetEngine()
        default:
            break
        }
        return SpeechAnalyzerEngine()
    }
}
