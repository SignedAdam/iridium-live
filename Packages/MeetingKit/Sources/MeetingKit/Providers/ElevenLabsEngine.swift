import Foundation

public final class ElevenLabsEngine: TranscriptionEngine, @unchecked Sendable {

    public let id = EngineID.elevenLabs
    public let displayName = "ElevenLabs Scribe v2"
    public let supportsDiarization = true
    public let isLocal = false

    private let apiKey: String

    private let modelID = "scribe_v2"

    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func transcribe(
        fileURL: URL,
        options: TranscriptionOptions,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> RawTranscript {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TranscriptionError.missingAPIKey("ElevenLabs")
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw TranscriptionError.network("Could not read audio file: \(error.localizedDescription)")
        }
        guard !audioData.isEmpty else { throw TranscriptionError.noAudio }

        try Task.checkCancellation()

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            options: options
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        progress(0.1)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("No HTTP response from ElevenLabs.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.provider(Self.describeError(status: http.statusCode, body: data))
        }

        let decoded: ELScribeResponse
        do {
            decoded = try JSONDecoder().decode(ELScribeResponse.self, from: data)
        } catch {
            throw TranscriptionError.provider("Could not parse ElevenLabs response: \(error.localizedDescription)")
        }

        let words = Self.mapWords(decoded.words ?? [])
        let segments = Self.makeSegments(from: words)

        progress(1.0)

        return RawTranscript(
            words: words,
            speakerSegments: segments.isEmpty ? nil : segments,
            language: decoded.language_code
        )
    }

    private func makeMultipartBody(
        boundary: String,
        audioData: Data,
        fileName: String,
        options: TranscriptionOptions
    ) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        appendField("model_id", modelID)

        appendField("timestamps_granularity", "word")

        appendField("tag_audio_events", "true")

        if options.diarize {
            appendField("diarize", "true")
            if let maxSpeakers = options.maxSpeakers, maxSpeakers > 0 {
                appendField("num_speakers", String(min(maxSpeakers, 32)))
            }
        } else {
            appendField("diarize", "false")
        }

        if let hint = options.languageHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            appendField("language_code", hint)
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(Self.mimeType(for: fileName))\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }

    private static func mapWords(_ words: [ELScribeWord]) -> [TranscriptWord] {
        words.compactMap { word in
            let type = word.type ?? "word"
            guard type == "word" else { return nil }

            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            guard let start = word.start, let end = word.end else { return nil }

            return TranscriptWord(
                text: text,
                start: start,
                end: max(start, end),
                confidence: word.logprob.map(confidence(fromLogProb:)),
                speakerID: word.speaker_id
            )
        }
    }

    private static func confidence(fromLogProb logProb: Double) -> Float {
        let p = exp(logProb)
        return Float(min(1.0, max(0.0, p)))
    }

    private static func makeSegments(from words: [TranscriptWord]) -> [DiarizationSegment] {
        var segments: [DiarizationSegment] = []
        for word in words {
            guard let speaker = word.speakerID else { continue }
            if !segments.isEmpty, segments[segments.count - 1].speakerID == speaker {
                segments[segments.count - 1].end = max(segments[segments.count - 1].end, word.end)
            } else {
                segments.append(DiarizationSegment(speakerID: speaker, start: word.start, end: word.end))
            }
        }
        return segments
    }

    private static func describeError(status: Int, body: Data) -> String {
        let prefix = "ElevenLabs request failed (HTTP \(status))"
        guard !body.isEmpty else { return prefix + "." }

        if let envelope = try? JSONDecoder().decode(ELScribeErrorEnvelope.self, from: body),
           let message = envelope.message {
            return "\(prefix): \(message)"
        }
        if let raw = String(data: body, encoding: .utf8), !raw.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(prefix): \(trimmed)"
        }
        return prefix + "."
    }
}

private struct ELScribeResponse: Decodable {
    let language_code: String?
    let text: String?
    let words: [ELScribeWord]?
}

private struct ELScribeWord: Decodable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String?
    let speaker_id: String?
    let logprob: Double?
}

private struct ELScribeErrorEnvelope: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey { case detail, message, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let direct = try? container.decode(String.self, forKey: .message) {
            message = direct
            return
        }
        if let errString = try? container.decode(String.self, forKey: .error) {
            message = errString
            return
        }

        if let detailString = try? container.decode(String.self, forKey: .detail) {
            message = detailString
            return
        }
        if let detailObject = try? container.decode(ELScribeErrorDetail.self, forKey: .detail) {
            message = detailObject.message
            return
        }
        if let detailArray = try? container.decode([ELScribeErrorDetail].self, forKey: .detail) {
            message = detailArray.compactMap { $0.message }.first
            return
        }

        message = nil
    }
}

private struct ELScribeErrorDetail: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey { case msg, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let msg = try? container.decode(String.self, forKey: .msg) {
            message = msg
        } else if let m = try? container.decode(String.self, forKey: .message) {
            message = m
        } else {
            message = nil
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
