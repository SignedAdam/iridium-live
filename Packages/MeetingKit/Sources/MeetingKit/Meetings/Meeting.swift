import Foundation

public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case none, running, done, failed }

    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var folderName: String
    public var hasMic: Bool
    public var hasSystem: Bool
    public var engineID: String?
    public var state: State
    public var error: String?
    public var createdAt: Date
    public var isArchived: Bool
    public var transcript: Transcript?
    public var summary: MeetingSummary?
    public var chat: [ChatMessage]
    public var speakerNames: [String: String]

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        folderName: String,
        hasMic: Bool,
        hasSystem: Bool,
        engineID: String? = nil,
        state: State = .none,
        error: String? = nil,
        createdAt: Date = Date(),
        isArchived: Bool = false,
        transcript: Transcript? = nil,
        summary: MeetingSummary? = nil,
        chat: [ChatMessage] = [],
        speakerNames: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.folderName = folderName
        self.hasMic = hasMic
        self.hasSystem = hasSystem
        self.engineID = engineID
        self.state = state
        self.error = error
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.transcript = transcript
        self.summary = summary
        self.chat = chat
        self.speakerNames = speakerNames
    }

    public var resolvedTranscript: Transcript? {
        guard var t = transcript else { return nil }
        for (id, name) in speakerNames { t.speakerNames[id] = name }
        return t
    }

    public var searchableText: String {
        var parts = [title]
        if let t = transcript { parts.append(t.plainText) }
        if let s = summary { parts.append(s.tldr); parts.append(contentsOf: s.keyPoints) }
        return parts.joined(separator: " ")
    }

    public var needsSpeakerAssignment: Bool {
        guard let t = transcript, speakerNames.isEmpty else { return false }
        return t.speakerIDs.filter { $0 != AudioStreamKind.mic.defaultSpeakerLabel }.count >= 2
    }

    public static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, h:mm a"
        return f.string(from: date)
    }

    init(from finished: RecordingCoordinator.FinishedSession) {
        let m = finished.manifest
        self.init(
            title: Meeting.defaultTitle(for: m.startedAt),
            startedAt: m.startedAt,
            duration: m.duration,
            folderName: finished.folder.lastPathComponent,
            hasMic: m.stream(.mic)?.segments.isEmpty == false,
            hasSystem: m.stream(.system)?.segments.isEmpty == false
        )
    }
}
