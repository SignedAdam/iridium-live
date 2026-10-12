import Foundation

public final class ClaudeProvider: IntelligenceProvider, @unchecked Sendable {

    public var id: String { "anthropic.claude" }
    public var displayName: String { "Claude (Anthropic)" }

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let transcriptCharLimit = 120_000
    private static let maxTokens = 2000

    public init(apiKey: String, model: String = "claude-opus-4-8") {
        self.apiKey = apiKey
        self.model = model
        self.session = .shared
    }

    public func summarize(transcript: Transcript, context: String?) async throws -> MeetingSummary {
        try requireKey()

        var system = """
        You are an expert meeting note-taker. Read the speaker-labelled transcript \
        the user provides and produce a concise, accurate meeting summary.

        Respond with ONLY a single JSON object and nothing else — no prose, no \
        explanation, no Markdown code fences. The JSON MUST match this exact shape:

        {
          "tldr": "string — a 1-3 sentence high-level summary",
          "keyPoints": ["string", ...],
          "actionItems": [{"text": "string", "owner": "string or null", "due": "string or null"}, ...],
          "decisions": [{"text": "string"}, ...],
          "chapters": [{"title": "string", "start": 0.0}, ...]
        }

        Rules:
        - "start" in each chapter is the offset in SECONDS as a number (Double).
        - Omit "owner"/"due" or set them to null when unknown.
        - Keep it concise: prefer a handful of crisp items over exhaustive lists.
        - Use the empty array [] for any section with no content. Never omit a key.
        """
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            system += "\n\nAdditional context about this meeting:\n\(context)"
        }

        let userContent = Self.truncate(transcript.labelledText, to: Self.transcriptCharLimit)
        let text = try await sendMessages(
            system: system,
            messages: [ELClaudeMessage(role: "user", content: userContent)]
        )

        guard
            let json = Self.extractJSONObject(from: text),
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(ELClaudeSummaryPayload.self, from: data)
        else {
            return MeetingSummary(tldr: text, generatedBy: "Claude")
        }

        return MeetingSummary(
            tldr: payload.tldr,
            keyPoints: payload.keyPoints ?? [],
            actionItems: (payload.actionItems ?? []).map {
                ActionItem(text: $0.text, owner: $0.owner, due: $0.due)
            },
            decisions: (payload.decisions ?? []).map { Decision(text: $0.text) },
            chapters: (payload.chapters ?? []).map { Chapter(title: $0.title, start: $0.start) },
            generatedBy: "Claude"
        )
    }

    public func chat(history: [ChatMessage], transcript: Transcript) async throws -> String {
        try requireKey()

        let system = """
        You are an assistant answering questions about this meeting transcript. \
        Cite speakers when relevant.

        Transcript:
        \(Self.truncate(transcript.labelledText, to: Self.transcriptCharLimit))
        """

        let messages = history.map {
            ELClaudeMessage(role: $0.role == .assistant ? "assistant" : "user", content: $0.text)
        }

        return try await sendMessages(system: system, messages: messages)
    }

    private func sendMessages(system: String, messages: [ELClaudeMessage]) async throws -> String {
        let body = ELClaudeRequest(
            model: model,
            maxTokens: Self.maxTokens,
            system: system,
            messages: messages
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw TranscriptionError.provider("Failed to encode Claude request: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("Unexpected response from Anthropic.")
        }

        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(ELClaudeErrorEnvelope.self, from: data) {
                throw TranscriptionError.provider("Claude API error (\(http.statusCode)): \(apiError.error.message)")
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.provider("Claude API error (\(http.statusCode)). \(raw)")
        }

        let decoded: ELClaudeResponse
        do {
            decoded = try JSONDecoder().decode(ELClaudeResponse.self, from: data)
        } catch {
            throw TranscriptionError.provider("Failed to decode Claude response: \(error.localizedDescription)")
        }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriptionError.provider("Claude returned an empty response.")
        }
        return text
    }

    private func requireKey() throws {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptionError.missingAPIKey("Anthropic")
        }
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[text.startIndex..<end]) + "\n…[transcript truncated]"
    }

    private static func extractJSONObject(from text: String) -> String? {
        var stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if stripped.hasPrefix("```") {
            if let firstNewline = stripped.firstIndex(of: "\n") {
                stripped = String(stripped[stripped.index(after: firstNewline)...])
            }
            if let fenceRange = stripped.range(of: "```", options: .backwards) {
                stripped = String(stripped[stripped.startIndex..<fenceRange.lowerBound])
            }
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let open = stripped.firstIndex(of: "{"),
            let close = stripped.lastIndex(of: "}"),
            open < close
        else {
            return nil
        }
        return String(stripped[open...close])
    }
}

private struct ELClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [ELClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct ELClaudeMessage: Encodable {
    let role: String
    let content: String
}

private struct ELClaudeResponse: Decodable {
    let content: [ELClaudeContentBlock]
}

private struct ELClaudeContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct ELClaudeErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let type: String
        let message: String
    }
    let error: ErrorBody
}

private struct ELClaudeSummaryPayload: Decodable {
    let tldr: String
    let keyPoints: [String]?
    let actionItems: [ActionItemPayload]?
    let decisions: [DecisionPayload]?
    let chapters: [ChapterPayload]?

    struct ActionItemPayload: Decodable {
        let text: String
        let owner: String?
        let due: String?
    }

    struct DecisionPayload: Decodable {
        let text: String
    }

    struct ChapterPayload: Decodable {
        let title: String
        let start: TimeInterval
    }
}
