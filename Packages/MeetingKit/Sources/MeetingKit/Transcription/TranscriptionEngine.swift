import Foundation

public struct TranscriptionOptions: Sendable {
    public var languageHint: String?
    public var diarize: Bool
    public var maxSpeakers: Int?

    public init(languageHint: String? = nil, diarize: Bool = true, maxSpeakers: Int? = nil) {
        self.languageHint = languageHint
        self.diarize = diarize
        self.maxSpeakers = maxSpeakers
    }
}

public struct RawTranscript: Sendable, Equatable {
    public var words: [TranscriptWord]
    public var speakerSegments: [DiarizationSegment]?
    public var language: String?

    public init(words: [TranscriptWord], speakerSegments: [DiarizationSegment]? = nil, language: String? = nil) {
        self.words = words
        self.speakerSegments = speakerSegments
        self.language = language
    }
}

public enum TranscriptionError: LocalizedError {
    case missingAPIKey(String)
    case network(String)
    case provider(String)
    case unsupported(String)
    case noAudio
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(name): return "Add your \(name) API key in Settings to use this engine."
        case let .network(message): return "Network error: \(message)"
        case let .provider(message): return message
        case let .unsupported(message): return message
        case .noAudio: return "There is no audio to transcribe."
        case .cancelled: return "Transcription was cancelled."
        }
    }
}

public protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportsDiarization: Bool { get }
    var isLocal: Bool { get }
    func transcribe(fileURL: URL, options: TranscriptionOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript
}

public enum EngineID {
    public static let appleSpeechAnalyzer = "apple.speechanalyzer"
    public static let parakeetLocal = "fluidaudio.parakeet"
    public static let elevenLabs = "cloud.elevenlabs"
    public static let assemblyAI = "cloud.assemblyai"
    public static let deepgram = "cloud.deepgram"
}
