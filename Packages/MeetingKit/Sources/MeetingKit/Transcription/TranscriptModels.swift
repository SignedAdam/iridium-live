import Foundation

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?
    public var speakerID: String?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil, speakerID: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speakerID = speakerID
    }
}

public struct SpeakerTurn: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var speakerID: String
    public var speakerName: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [TranscriptWord]
    public var styles: [TextStyleRun]?

    public init(id: UUID = UUID(), speakerID: String, speakerName: String? = nil, start: TimeInterval, end: TimeInterval, text: String, words: [TranscriptWord], styles: [TextStyleRun]? = nil) {
        self.id = id
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.styles = styles
    }

    public var displayName: String { speakerName ?? speakerID }
}

public struct DiarizationSegment: Codable, Equatable, Sendable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var turns: [SpeakerTurn]
    public var language: String?
    public var engineID: String
    public var createdAt: Date
    public var speakerNames: [String: String]

    public init(turns: [SpeakerTurn], language: String? = nil, engineID: String, createdAt: Date = Date(), speakerNames: [String: String] = [:]) {
        self.turns = turns
        self.language = language
        self.engineID = engineID
        self.createdAt = createdAt
        self.speakerNames = speakerNames
    }

    public var speakerIDs: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for t in turns where !seen.contains(t.speakerID) {
            seen.insert(t.speakerID)
            order.append(t.speakerID)
        }
        return order
    }

    public func name(for speakerID: String) -> String {
        speakerNames[speakerID] ?? speakerID
    }

    public var plainText: String {
        turns.map(\.text).joined(separator: "\n")
    }

    public var labelledText: String {
        turns.map { "\(name(for: $0.speakerID)): \($0.text)" }.joined(separator: "\n\n")
    }

    public var duration: TimeInterval { turns.last?.end ?? 0 }
    public var wordCount: Int { turns.reduce(0) { $0 + $1.words.count } }
}
