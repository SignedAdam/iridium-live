import Foundation

public final class OpenRouterProvider: IntelligenceProvider, @unchecked Sendable {

    public var id: String { "openrouter" }
    public var displayName: String { "OpenRouter" }

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let transcriptCharLimit = 120_000
    private static let maxTokens = 2000

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "anthropic/claude-3.5-sonnet" : model
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
        let text = try await sendChat(messages: [
            ORMessage(role: "system", content: system),
            ORMessage(role: "user", content: userContent),
        ])

        guard
            let json = Self.extractJSONObject(from: text),
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(ORSummaryPayload.self, from: data)
        else {
            return MeetingSummary(tldr: text, generatedBy: "OpenRouter")
        }

        return MeetingSummary(
            tldr: payload.tldr,
            keyPoints: payload.keyPoints ?? [],
            actionItems: (payload.actionItems ?? []).map { ActionItem(text: $0.text, owner: $0.owner, due: $0.due) },
            decisions: (payload.decisions ?? []).map { Decision(text: $0.text) },
            chapters: (payload.chapters ?? []).map { Chapter(title: $0.title, start: $0.start) },
            generatedBy: "OpenRouter (\(model))"
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

        var messages = [ORMessage(role: "system", content: system)]
        messages += history.map { ORMessage(role: $0.role == .assistant ? "assistant" : "user", content: $0.text) }
        return try await sendChat(messages: messages)
    }

    private func sendChat(messages: [ORMessage]) async throws -> String {
        let body = ORRequest(model: model, messages: messages, maxTokens: Self.maxTokens)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/SignedAdam/iridium-live", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Iridium Live", forHTTPHeaderField: "X-Title")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw TranscriptionError.provider("Failed to encode OpenRouter request: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("Unexpected response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(ORErrorEnvelope.self, from: data) {
                throw TranscriptionError.provider("OpenRouter error (\(http.statusCode)): \(apiError.error.message)")
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.provider("OpenRouter error (\(http.statusCode)). \(raw)")
        }

        let decoded: ORResponse
        do {
            decoded = try JSONDecoder().decode(ORResponse.self, from: data)
        } catch {
            throw TranscriptionError.provider("Failed to decode OpenRouter response: \(error.localizedDescription)")
        }

        let text = (decoded.choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.provider("OpenRouter returned an empty response.")
        }
        return text
    }

    private func requireKey() throws {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptionError.missingAPIKey("OpenRouter")
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
        guard let open = stripped.firstIndex(of: "{"),
              let close = stripped.lastIndex(of: "}"), open < close else { return nil }
        return String(stripped[open...close])
    }
}

private struct ORRequest: Encodable {
    let model: String
    let messages: [ORMessage]
    let maxTokens: Int
    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }
}

private struct ORMessage: Codable {
    let role: String
    let content: String
}

private struct ORResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let message: ORMessage }
}

private struct ORErrorEnvelope: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
}

private struct ORSummaryPayload: Decodable {
    let tldr: String
    let keyPoints: [String]?
    let actionItems: [ActionItemPayload]?
    let decisions: [DecisionPayload]?
    let chapters: [ChapterPayload]?
    struct ActionItemPayload: Decodable { let text: String; let owner: String?; let due: String? }
    struct DecisionPayload: Decodable { let text: String }
    struct ChapterPayload: Decodable { let title: String; let start: TimeInterval }
}
