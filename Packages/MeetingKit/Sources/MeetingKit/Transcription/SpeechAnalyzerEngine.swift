import Foundation
import AVFoundation
import CoreMedia
import Speech

final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    let id = EngineID.appleSpeechAnalyzer
    let displayName = "Apple Speech (On-Device)"
    let supportsDiarization = false
    let isLocal = true

    func transcribe(fileURL: URL, options: TranscriptionOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        let locale = await Self.bestLocale(for: options.languageHint)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            throw TranscriptionError.noAudio
        }
        let totalSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let collector = Task<[TranscriptWord], Error> {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                let attributed = result.text
                for run in attributed.runs {
                    guard let timeRange = run.audioTimeRange else { continue }
                    let piece = String(attributed[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !piece.isEmpty else { continue }
                    let start = timeRange.start.seconds
                    let end = timeRange.end.seconds
                    words.append(TranscriptWord(text: piece,
                                                start: start.isFinite ? start : 0,
                                                end: end.isFinite ? end : start))
                    if totalSeconds > 0 {
                        progress(min(0.99, end / totalSeconds))
                    }
                }
            }
            return words
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            collector.cancel()
            throw TranscriptionError.provider("Speech analysis failed: \(error.localizedDescription)")
        }

        let words = try await collector.value
        progress(1.0)
        return RawTranscript(words: words, speakerSegments: nil, language: locale.identifier)
    }

    static func bestLocale(for hint: String?) async -> Locale {
        let desired = Locale(identifier: hint ?? "en-US")
        let supported = await SpeechTranscriber.supportedLocales
        if supported.isEmpty { return desired }
        if let exact = supported.first(where: { $0.identifier(.bcp47) == desired.identifier(.bcp47) }) {
            return exact
        }
        if let sameLanguage = supported.first(where: {
            $0.language.languageCode == desired.language.languageCode
        }) {
            return sameLanguage
        }
        return supported.first(where: { $0.language.languageCode?.identifier == "en" }) ?? supported[0]
    }
}
