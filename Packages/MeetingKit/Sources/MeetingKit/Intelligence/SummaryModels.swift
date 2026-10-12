import Foundation

public struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var owner: String?
    public var due: String?
    public var done: Bool

    public init(id: UUID = UUID(), text: String, owner: String? = nil, due: String? = nil, done: Bool = false) {
        self.id = id
        self.text = text
        self.owner = owner
        self.due = due
        self.done = done
    }
}

public struct Decision: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
}

public struct Chapter: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var start: TimeInterval
    public init(id: UUID = UUID(), title: String, start: TimeInterval) {
        self.id = id
        self.title = title
        self.start = start
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public var tldr: String
    public var keyPoints: [String]
    public var actionItems: [ActionItem]
    public var decisions: [Decision]
    public var chapters: [Chapter]
    public var generatedBy: String
    public var createdAt: Date

    public init(
        tldr: String,
        keyPoints: [String] = [],
        actionItems: [ActionItem] = [],
        decisions: [Decision] = [],
        chapters: [Chapter] = [],
        generatedBy: String,
        createdAt: Date = Date()
    ) {
        self.tldr = tldr
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.decisions = decisions
        self.chapters = chapters
        self.generatedBy = generatedBy
        self.createdAt = createdAt
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public protocol IntelligenceProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func summarize(transcript: Transcript, context: String?) async throws -> MeetingSummary
    func chat(history: [ChatMessage], transcript: Transcript) async throws -> String
}
