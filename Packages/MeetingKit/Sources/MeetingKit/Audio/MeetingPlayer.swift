import Foundation
import AVFoundation
import Observation

struct PlaybackPreparer {
    private let targetSampleRate: Double = 48_000
    private let targetChannels: AVAudioChannelCount = 1

    static let cacheFileName = "playback-v2.m4a"

    func playbackURL(folder: URL, manifest: RecordingManifest) throws -> URL? {
        let outURL = folder.appendingPathComponent(Self.cacheFileName)

        if FileManager.default.fileExists(atPath: outURL.path) {
            return outURL
        }

        let pads = manifest.streamLeadingSilence()
        var byKind: [AudioStreamKind: [Float]] = [:]
        for kind in [AudioStreamKind.mic, .system] {
            guard let stream = manifest.stream(kind) else { continue }
            var samples = concatenatedSamples(for: stream, in: folder)
            if samples.isEmpty { continue }
            let pad = Int(((pads[kind] ?? 0) * targetSampleRate).rounded())
            if pad > 0 { samples = [Float](repeating: 0, count: pad) + samples }
            byKind[kind] = samples
        }
        guard !byKind.isEmpty else { return nil }

        let streamSamples: [[Float]]
        if let mic = byKind[.mic], let sys = byKind[.system],
           SpeakerBleed.isBleeding(mic, targetSampleRate, sys, targetSampleRate) {
            streamSamples = [mic]
        } else {
            streamSamples = Array(byKind.values)
        }

        let length = streamSamples.map(\.count).max() ?? 0
        guard length > 0 else { return nil }
        var mixed = [Float](repeating: 0, count: length)
        for samples in streamSamples {
            for i in 0..<samples.count { mixed[i] += samples[i] }
        }
        for i in 0..<length { mixed[i] = max(-1, min(1, mixed[i])) }

        let tmpURL = folder.appendingPathComponent("playback-\(UUID().uuidString).m4a")
        do {
            try writeAAC(mixed, to: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: tmpURL, to: outURL)
        return outURL
    }

    private func concatenatedSamples(for stream: StreamManifest, in folder: URL) -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else { return [] }

        var out: [Float] = []
        for segment in stream.segments.sorted(by: { $0.index < $1.index }) {
            let url = folder.appendingPathComponent(segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let inFile = try? AVAudioFile(forReading: url) else { continue }
            if let samples = try? convertedSamples(from: inFile, to: targetFormat) {
                out.append(contentsOf: samples)
            }
        }
        return out
    }

    private func convertedSamples(from inFile: AVAudioFile, to targetFormat: AVAudioFormat) throws -> [Float] {
        let inFormat = inFile.processingFormat
        let frameCount = AVAudioFrameCount(inFile.length)
        guard frameCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: targetFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else { return [] }

        try inFile.read(into: inBuf)
        guard inBuf.frameLength > 0 else { return [] }

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4_096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return [] }

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
        guard status != .error, outBuf.frameLength > 0,
              let channelData = outBuf.floatChannelData else { return [] }

        let n = Int(outBuf.frameLength)
        var samples = [Float](repeating: 0, count: n)
        samples.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: channelData[0], count: n)
        }
        return samples
    }

    private var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: Int(targetChannels),
        ]
    }

    private func writeAAC(_ samples: [Float], to url: URL) throws {
        let outFile = try AVAudioFile(forWriting: url, settings: aacSettings)
        let format = outFile.processingFormat
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw AudioError("Could not allocate playback write buffer.")
        }

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
}

enum SpeakerBleed {
    static let threshold = 0.5
    static let maxLagSeconds = 1.0

    static func isBleeding(_ mic: [Float], _ micRate: Double, _ sys: [Float], _ sysRate: Double) -> Bool {
        correlation(mic, micRate, sys, sysRate) > threshold
    }

    static func correlation(_ mic: [Float], _ micRate: Double, _ sys: [Float], _ sysRate: Double) -> Double {
        let frameMS = 50.0
        let em = envelope(mic, micRate, frameMS: frameMS)
        let es = envelope(sys, sysRate, frameMS: frameMS)
        let maxLag = Int(maxLagSeconds * 1000 / frameMS)
        var best = 0.0
        for lag in 0...maxLag {
            best = max(best, pearson(em, es, micLag: lag))
        }
        return best
    }

    private static func pearson(_ em: [Float], _ es: [Float], micLag lag: Int) -> Double {
        let n = min(em.count - lag, es.count)
        guard n > 40 else { return 0 }
        var ma: Float = 0, mb: Float = 0
        for k in 0..<n { ma += em[k + lag]; mb += es[k] }
        ma /= Float(n); mb /= Float(n)
        var num = 0.0, da = 0.0, db = 0.0
        for k in 0..<n {
            let xa = Double(em[k + lag] - ma), xb = Double(es[k] - mb)
            num += xa * xb; da += xa * xa; db += xb * xb
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }

    static func envelope(_ samples: [Float], _ sampleRate: Double, frameMS: Double = 50) -> [Float] {
        let fs = max(1, Int(sampleRate * frameMS / 1000))
        var out: [Float] = []
        out.reserveCapacity(samples.count / fs + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + fs, samples.count)
            var s: Float = 0
            for j in i..<end { s += samples[j] * samples[j] }
            out.append((s / Float(end - i)).squareRoot())
            i = end
        }
        return out
    }
}

@MainActor
@Observable
public final class MeetingPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    public var isPlaying = false
    public var currentTime: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var loadedURL: URL?
    public private(set) var playbackEnd: TimeInterval?

    @ObservationIgnored private var boundedRewind: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    private let tickInterval: TimeInterval = 0.05

    deinit {
        ticker?.invalidate()
    }

    public func load(_ url: URL) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            loadedURL = url
            duration = p.duration
            currentTime = 0
        } catch {
            player = nil
            loadedURL = nil
            duration = 0
            currentTime = 0
        }
    }

    public func togglePlay() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard let player else { return }
        playbackEnd = nil
        guard player.play() else { return }
        isPlaying = true
        startTicker()
    }

    public func play(from start: TimeInterval, until end: TimeInterval, rewindTo rewind: TimeInterval? = nil) {
        guard let player else { return }
        let from = max(0, min(start, duration))
        let until = max(0, min(end, duration))
        guard until > from else { return }
        player.currentTime = from
        currentTime = from
        guard player.play() else {
            playbackEnd = nil
            isPlaying = player.isPlaying
            return
        }
        playbackEnd = until
        boundedRewind = max(0, min(rewind ?? from, until))
        isPlaying = true
        startTicker()
    }

    public func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        playbackEnd = nil
        stopTicker()
        currentTime = player.currentTime
    }

    public func seek(to t: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(t, duration))
        player.currentTime = clamped
        currentTime = clamped
        if let end = playbackEnd, !(boundedRewind...end).contains(clamped) {
            playbackEnd = nil
        }
    }

    public func stop() {
        stopTicker()
        if let player {
            player.stop()
            player.currentTime = 0
        }
        isPlaying = false
        playbackEnd = nil
        currentTime = 0
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player, player.isPlaying else { return }
        currentTime = player.currentTime
        if let end = playbackEnd, currentTime >= end {
            finishBoundedPlay()
        }
    }

    private func finishBoundedPlay() {
        stopTicker()
        player?.pause()
        player?.currentTime = boundedRewind
        isPlaying = false
        currentTime = boundedRewind
        playbackEnd = nil
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            if self.playbackEnd != nil {
                self.finishBoundedPlay()
                return
            }
            self.stopTicker()
            self.isPlaying = false
            self.currentTime = 0
            self.player?.currentTime = 0
        }
    }
}
