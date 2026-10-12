import Foundation
internal import FluidAudio

actor ParakeetASRService {
    static let shared = ParakeetASRService()
    private var manager: AsrManager?

    private func ensureLoaded() async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        let manager = try await ensureLoaded()
        var state = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &state, language: nil)
    }
}

final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    let id = EngineID.parakeetLocal
    let displayName = "NVIDIA Parakeet (On-Device)"
    let supportsDiarization = false
    let isLocal = true

    func transcribe(fileURL: URL, options: TranscriptionOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        let (samples, _) = try AudioPreparer().loadMonoFloats(fileURL)
        guard !samples.isEmpty else { throw TranscriptionError.noAudio }
        progress(0.1)
        let result: ASRResult
        do {
            result = try await ParakeetASRService.shared.transcribe(samples)
        } catch {
            throw TranscriptionError.provider("Parakeet (FluidAudio) failed: \(error.localizedDescription)")
        }
        progress(0.95)
        let words = Self.words(from: result)
        progress(1.0)
        return RawTranscript(words: words, speakerSegments: nil, language: "en")
    }

    static func words(from result: ASRResult) -> [TranscriptWord] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptWord(text: text, start: 0, end: result.duration)]
        }
        let boundary: Character = "\u{2581}"
        var words: [TranscriptWord] = []
        var current: [TokenTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.token).joined()
                .replacingOccurrences(of: String(boundary), with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                let conf = current.map(\.confidence).reduce(0, +) / Float(current.count)
                words.append(TranscriptWord(text: text, start: first.startTime, end: last.endTime, confidence: conf))
            }
            current.removeAll()
        }

        for timing in timings {
            if timing.token.first == boundary && !current.isEmpty { flush() }
            current.append(timing)
        }
        flush()
        return words
    }
}

actor OfflineDiarizerService {
    static let shared = OfflineDiarizerService()
    private var manager: OfflineDiarizerManager?

    private func ensureLoaded() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        self.manager = manager
        return manager
    }

    func diarize(_ samples: [Float]) async throws -> [DiarizationSegment] {
        let manager = try await ensureLoaded()
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            DiarizationSegment(speakerID: $0.speakerId,
                               start: TimeInterval($0.startTimeSeconds),
                               end: TimeInterval($0.endTimeSeconds))
        }
    }
}

struct FluidAudioDiarizer: SystemChannelDiarizing {
    func diarizeSystemChannel(fileURL: URL) async throws -> [DiarizationSegment] {
        let (samples, sampleRate) = try AudioPreparer().loadMonoFloats(fileURL)
        guard Double(samples.count) > sampleRate else { return [] }
        return try await OfflineDiarizerService.shared.diarize(samples)
    }
}
