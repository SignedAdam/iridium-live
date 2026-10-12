import Foundation
import AVFoundation

struct AudioPreparer {
    private var storageSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    func prepareStream(_ stream: StreamManifest, in folder: URL, leadingSilence: TimeInterval = 0) throws -> URL? {
        let segments = stream.segments.sorted { $0.index < $1.index }
        guard !segments.isEmpty else { return nil }
        let outURL = folder.appendingPathComponent("\(stream.kind.fileBaseName)-16k.wav")
        try? FileManager.default.removeItem(at: outURL)

        let outFile = try AVAudioFile(forWriting: outURL, settings: storageSettings)
        let outFormat = outFile.processingFormat
        var wroteAny = false

        if leadingSilence > 0 {
            try writeSilence(seconds: leadingSilence, to: outFile, format: outFormat)
            wroteAny = true
        }

        for segment in segments {
            let url = folder.appendingPathComponent(segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let inFile = try? AVAudioFile(forReading: url) else { continue }
            if try appendConverted(from: inFile, to: outFile, outFormat: outFormat) { wroteAny = true }
        }
        return wroteAny ? outURL : nil
    }

    func mix(_ urls: [URL], to outURL: URL) throws -> URL {
        let loaded = try urls.map { try loadMonoFloats($0).samples }
        let length = loaded.map(\.count).max() ?? 0
        guard length > 0 else { throw AudioError("Nothing to mix.") }
        var mixed = [Float](repeating: 0, count: length)
        for samples in loaded {
            for i in 0..<samples.count { mixed[i] += samples[i] }
        }
        for i in 0..<length { mixed[i] = max(-1, min(1, mixed[i])) }
        try writeMonoFloats(mixed, to: outURL)
        return outURL
    }

    func loadMonoFloats(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        guard n > 0, let channelData = buffer.floatChannelData else { return ([], format.sampleRate) }
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: channelData[0], count: n)
            }
        } else {
            for f in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += channelData[c][f] }
                mono[f] = s / Float(channels)
            }
        }
        return (mono, format.sampleRate)
    }

    func writeMonoFloats(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let outFile = try AVAudioFile(forWriting: url, settings: storageSettings)
        let format = outFile.processingFormat
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            buffer.frameLength = AVAudioFrameCount(n)
            if let dst = buffer.floatChannelData?[0] {
                for i in 0..<n { dst[i] = samples[offset + i] }
            }
            try outFile.write(from: buffer)
            offset += n
        }
    }

    private func writeSilence(seconds: TimeInterval, to outFile: AVAudioFile, format: AVAudioFormat) throws {
        var remaining = Int((seconds * format.sampleRate).rounded())
        guard remaining > 0 else { return }
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        while remaining > 0 {
            let n = min(chunk, remaining)
            buffer.frameLength = AVAudioFrameCount(n)
            if let dst = buffer.floatChannelData?[0] {
                for i in 0..<n { dst[i] = 0 }
            }
            try outFile.write(from: buffer)
            remaining -= n
        }
    }

    @discardableResult
    private func appendConverted(from inFile: AVAudioFile, to outFile: AVAudioFile, outFormat: AVAudioFormat) throws -> Bool {
        let inFormat = inFile.processingFormat
        let frameCount = AVAudioFrameCount(inFile.length)
        guard frameCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else { return false }
        try inFile.read(into: inBuf)
        guard inBuf.frameLength > 0 else { return false }

        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4_096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return false }

        var provided = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
            if provided {
                inStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            inStatus.pointee = .haveData
            return inBuf
        }
        if let convError { throw convError }
        guard status != .error, outBuf.frameLength > 0 else { return false }
        try outFile.write(from: outBuf)
        return true
    }
}
