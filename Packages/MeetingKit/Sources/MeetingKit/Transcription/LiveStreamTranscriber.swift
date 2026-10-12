import Foundation
import AVFoundation
import Speech

final class LiveStreamTranscriber: @unchecked Sendable {
    typealias Update = @Sendable (_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ isFinal: Bool) -> Void

    let kind: AudioStreamKind
    private let sessionStart: Date
    private let buffers: AsyncStream<AVAudioPCMBuffer>
    private let input: AsyncStream<AVAudioPCMBuffer>.Continuation

    private let lock = NSLock()
    private var offset: TimeInterval?
    private var monoFormat: AVAudioFormat?

    init(kind: AudioStreamKind, sessionStart: Date) {
        self.kind = kind
        self.sessionStart = sessionStart
        (buffers, input) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
    }

    func append(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Double) {
        guard frames > 0, channels > 0, sampleRate > 0 else { return }
        lock.lock()
        if offset == nil {
            offset = max(0, Date().timeIntervalSince(sessionStart) - Double(frames) / sampleRate)
        }
        if monoFormat?.sampleRate != sampleRate {
            monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        }
        let format = monoFormat
        lock.unlock()

        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return }
        if channels == 1 {
            out.update(from: samples, count: frames)
        } else {
            let scale = 1 / Float(channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f * channels + c] }
                out[f] = sum * scale
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        input.yield(buffer)
    }

    func finish() {
        input.finish()
    }

    func run(locale: Locale, onUpdate: @escaping Update) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AudioError("No audio format is available for on-device speech recognition.")
        }
        let (analyzerInput, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: analyzerInput)

        let results = Task {
            for try await result in transcriber.results {
                let base = self.timelineOffset
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                guard start.isFinite else { continue }
                onUpdate(String(result.text.characters), base + start,
                         base + (end.isFinite ? end : start), result.isFinal)
            }
        }

        var converter: AVAudioConverter?
        for await buffer in buffers {
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter, let converted = Self.convert(buffer, with: converter, to: format) else { continue }
            feed.yield(AnalyzerInput(buffer: converted))
        }
        feed.finish()

        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            return
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results.value
    }

    private var timelineOffset: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return offset ?? 0
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
