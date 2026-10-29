import Foundation

public struct MeetingConfig: Sendable {
    public var engineID: String
    public var languageHint: String
    public var recordMic: Bool
    public var recordSystem: Bool
    public var microphoneUID: String?
    /// Transcribe as soon as the meeting ends, instead of leaving the recording for later.
    public var autoTranscribe: Bool
    /// Run the live transcript while recording.
    public var liveTranscript: Bool
    public var summaryProvider: String
    public var summaryModel: String
    public var hasKey: @Sendable (String) -> Bool
    public var key: @Sendable (String) -> String?

    public init(
        engineID: String,
        languageHint: String,
        recordMic: Bool,
        recordSystem: Bool,
        microphoneUID: String?,
        autoTranscribe: Bool,
        liveTranscript: Bool,
        summaryProvider: String,
        summaryModel: String,
        hasKey: @escaping @Sendable (String) -> Bool,
        key: @escaping @Sendable (String) -> String?
    ) {
        self.engineID = engineID
        self.languageHint = languageHint
        self.recordMic = recordMic
        self.recordSystem = recordSystem
        self.microphoneUID = microphoneUID
        self.autoTranscribe = autoTranscribe
        self.liveTranscript = liveTranscript
        self.summaryProvider = summaryProvider
        self.summaryModel = summaryModel
        self.hasKey = hasKey
        self.key = key
    }
}
