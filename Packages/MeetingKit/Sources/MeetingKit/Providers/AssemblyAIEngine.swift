import Foundation

public final class AssemblyAIEngine: TranscriptionEngine, @unchecked Sendable {

    public let id = EngineID.assemblyAI
    public let displayName = "AssemblyAI Universal-3"
    public let supportsDiarization = true
    public let isLocal = false

    private let apiKey: String
    private let session: URLSession

    private static let baseURL = URL(string: "https://api.assemblyai.com/v2")!

    private static let pollInterval: Duration = .seconds(2)

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.session = .shared
    }

    public func transcribe(
        fileURL: URL,
        options: TranscriptionOptions,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> RawTranscript {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TranscriptionError.missingAPIKey("AssemblyAI")
        }

        progress(0.0)
        let uploadURL = try await uploadAudio(fileURL: fileURL, key: key)
        try Task.checkCancellation()
        progress(0.2)

        let transcriptID = try await submitJob(audioURL: uploadURL, options: options, key: key)
        try Task.checkCancellation()
        progress(0.3)

        let response = try await pollUntilDone(transcriptID: transcriptID, key: key, progress: progress)
        progress(1.0)

        return makeRawTranscript(from: response, options: options)
    }

    private func uploadAudio(fileURL: URL, key: String) async throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw TranscriptionError.noAudio
        }
        guard !data.isEmpty else { throw TranscriptionError.noAudio }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (body, http) = try await performUpload(request, from: data)
        try Self.validate(http, body: body)

        let decoded = try Self.decode(ELAssemblyUploadResponse.self, from: body)
        return decoded.upload_url
    }

    private func submitJob(audioURL: String, options: TranscriptionOptions, key: String) async throws -> String {
        var payload = ELAssemblyTranscriptRequest(
            audio_url: audioURL,
            speaker_labels: options.diarize,
            speech_models: ["universal-3-pro", "universal-2"]
        )

        if options.diarize, let maxSpeakers = options.maxSpeakers, maxSpeakers > 0 {
            payload.speakers_expected = maxSpeakers
        }

        if let hint = options.languageHint, !hint.isEmpty {
            payload.language_code = hint
        } else {
            payload.language_detection = true
        }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("transcript"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encode(payload)

        let (body, http) = try await performData(request)
        try Self.validate(http, body: body)

        let decoded = try Self.decode(ELAssemblyTranscriptResponse.self, from: body)
        guard let id = decoded.id else {
            throw TranscriptionError.provider("AssemblyAI did not return a transcript ID.")
        }
        return id
    }

    private func pollUntilDone(
        transcriptID: String,
        key: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ELAssemblyTranscriptResponse {
        let url = Self.baseURL
            .appendingPathComponent("transcript")
            .appendingPathComponent(transcriptID)

        var poll = 0
        while true {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "authorization")

            let (body, http) = try await performData(request)
            try Self.validate(http, body: body)

            let response = try Self.decode(ELAssemblyTranscriptResponse.self, from: body)

            switch response.status {
            case "completed":
                return response
            case "error":
                let message = response.error ?? "AssemblyAI transcription failed."
                throw TranscriptionError.provider(message)
            default:
                poll += 1
                let creep = 0.3 + (1.0 - exp(-Double(poll) / 8.0)) * 0.65
                progress(min(0.95, creep))
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    throw TranscriptionError.cancelled
                }
            }
        }
    }

    private func makeRawTranscript(from response: ELAssemblyTranscriptResponse, options: TranscriptionOptions) -> RawTranscript {
        let words: [TranscriptWord] = (response.words ?? []).map { word in
            TranscriptWord(
                text: word.text,
                start: Self.msToSeconds(word.start),
                end: Self.msToSeconds(word.end),
                confidence: word.confidence.map { Float($0) },
                speakerID: word.speaker
            )
        }

        var segments: [DiarizationSegment]? = nil
        if options.diarize, let utterances = response.utterances, !utterances.isEmpty {
            segments = utterances.map { utterance in
                DiarizationSegment(
                    speakerID: utterance.speaker,
                    start: Self.msToSeconds(utterance.start),
                    end: Self.msToSeconds(utterance.end)
                )
            }
        }

        return RawTranscript(
            words: words,
            speakerSegments: segments,
            language: response.language_code
        )
    }

    private func performUpload(_ request: URLRequest, from data: Data) async throws -> (Data, HTTPURLResponse) {
        do {
            let (body, response) = try await session.upload(for: request, from: data)
            guard let http = response as? HTTPURLResponse else {
                throw TranscriptionError.network("Unexpected response from AssemblyAI.")
            }
            return (body, http)
        } catch let error as TranscriptionError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
    }

    private func performData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TranscriptionError.network("Unexpected response from AssemblyAI.")
            }
            return (body, http)
        } catch let error as TranscriptionError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
    }

    private static func validate(_ http: HTTPURLResponse, body: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw TranscriptionError.missingAPIKey("AssemblyAI")
            }
            if let apiError = try? decode(ELAssemblyErrorResponse.self, from: body), let message = apiError.error {
                throw TranscriptionError.provider(message)
            }
            let text = String(data: body, encoding: .utf8) ?? ""
            let detail = text.isEmpty ? "" : ": \(text)"
            throw TranscriptionError.provider("AssemblyAI request failed (HTTP \(http.statusCode))\(detail)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TranscriptionError.provider("Could not parse AssemblyAI response.")
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw TranscriptionError.provider("Could not encode AssemblyAI request.")
        }
    }

    private static func msToSeconds(_ ms: Int?) -> TimeInterval {
        guard let ms else { return 0 }
        return TimeInterval(ms) / 1000.0
    }
}

private struct ELAssemblyUploadResponse: Decodable {
    let upload_url: String
}

private struct ELAssemblyTranscriptRequest: Encodable {
    var audio_url: String
    var speaker_labels: Bool
    var speech_models: [String]
    var language_code: String? = nil
    var language_detection: Bool? = nil
    var speakers_expected: Int? = nil
}

private struct ELAssemblyTranscriptResponse: Decodable {
    let id: String?
    let status: String?
    let error: String?
    let language_code: String?
    let words: [ELAssemblyWord]?
    let utterances: [ELAssemblyUtterance]?
}

private struct ELAssemblyWord: Decodable {
    let text: String
    let start: Int?
    let end: Int?
    let confidence: Double?
    let speaker: String?
}

private struct ELAssemblyUtterance: Decodable {
    let speaker: String
    let start: Int?
    let end: Int?
    let text: String
}

private struct ELAssemblyErrorResponse: Decodable {
    let error: String?
}
