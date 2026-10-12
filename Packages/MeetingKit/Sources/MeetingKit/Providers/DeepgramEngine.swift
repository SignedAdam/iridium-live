import Foundation

public final class DeepgramEngine: TranscriptionEngine, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession

    public let id = EngineID.deepgram
    public let displayName = "Deepgram Nova-3"
    public let supportsDiarization = true
    public let isLocal = false

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func transcribe(
        fileURL: URL,
        options: TranscriptionOptions,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> RawTranscript {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TranscriptionError.missingAPIKey("Deepgram")
        }

        progress(0.1)

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize", value: options.diarize ? "true" : "false"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]
        if let hint = options.languageHint, !hint.isEmpty {
            query.append(URLQueryItem(name: "language", value: hint))
        } else {
            query.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        components.queryItems = query

        guard let url = components.url else {
            throw TranscriptionError.provider("Deepgram: failed to build request URL.")
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw TranscriptionError.noAudio
        }
        guard !audioData.isEmpty else { throw TranscriptionError.noAudio }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: audioData)
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("Deepgram: no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.provider(
                ELDeepgramError.message(from: data, statusCode: http.statusCode)
            )
        }

        let decoded: ELDeepgramResponse
        do {
            decoded = try JSONDecoder().decode(ELDeepgramResponse.self, from: data)
        } catch {
            throw TranscriptionError.provider("Deepgram: could not decode response (\(error.localizedDescription)).")
        }

        let transcript = decoded.toRawTranscript()
        progress(1.0)
        return transcript
    }
}

private struct ELDeepgramResponse: Decodable {
    let results: Results?

    struct Results: Decodable {
        let channels: [Channel]?
        let utterances: [Utterance]?
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]?
        let detectedLanguage: String?

        enum CodingKeys: String, CodingKey {
            case alternatives
            case detectedLanguage = "detected_language"
        }
    }

    struct Alternative: Decodable {
        let words: [Word]?
        let languages: [String]?
    }

    struct Word: Decodable {
        let word: String?
        let punctuatedWord: String?
        let start: TimeInterval?
        let end: TimeInterval?
        let confidence: Float?
        let speaker: Int?

        enum CodingKeys: String, CodingKey {
            case word
            case punctuatedWord = "punctuated_word"
            case start, end, confidence, speaker
        }

        var displayText: String { punctuatedWord ?? word ?? "" }
    }

    struct Utterance: Decodable {
        let start: TimeInterval?
        let end: TimeInterval?
        let speaker: Int?
    }

    func toRawTranscript() -> RawTranscript {
        let channel = results?.channels?.first
        let alternative = channel?.alternatives?.first

        let words: [TranscriptWord] = (alternative?.words ?? []).compactMap { w in
            let text = w.displayText
            guard !text.isEmpty else { return nil }
            let speakerID = w.speaker.map { "Speaker \($0)" }
            return TranscriptWord(
                text: text,
                start: w.start ?? 0,
                end: w.end ?? (w.start ?? 0),
                confidence: w.confidence,
                speakerID: speakerID
            )
        }

        let segments: [DiarizationSegment]? = results?.utterances?.compactMap { u in
            guard let speaker = u.speaker, let start = u.start, let end = u.end else { return nil }
            return DiarizationSegment(speakerID: "Speaker \(speaker)", start: start, end: end)
        }
        let speakerSegments = (segments?.isEmpty == false) ? segments : nil

        let language = channel?.detectedLanguage ?? alternative?.languages?.first

        return RawTranscript(words: words, speakerSegments: speakerSegments, language: language)
    }
}

private enum ELDeepgramError {
    static func message(from data: Data, statusCode: Int) -> String {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            if let msg = envelope.errMsg ?? envelope.message ?? envelope.reason, !msg.isEmpty {
                return "Deepgram (\(statusCode)): \(msg)"
            }
        }
        if let body = String(data: data, encoding: .utf8),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Deepgram (\(statusCode)): \(body)"
        }
        return "Deepgram request failed with status \(statusCode)."
    }

    private struct Envelope: Decodable {
        let errMsg: String?
        let message: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case errMsg = "err_msg"
            case message
            case reason
        }
    }
}
