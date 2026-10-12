import Foundation

public struct MeetingConfig: Sendable {
    public var engineID: String
    public var languageHint: String
    public var recordMic: Bool
    public var recordSystem: Bool
    public var microphoneUID: String?
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
        self.summaryProvider = summaryProvider
        self.summaryModel = summaryModel
        self.hasKey = hasKey
        self.key = key
    }
}
