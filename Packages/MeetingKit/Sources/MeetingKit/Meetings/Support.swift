import Foundation
import AVFoundation

public func formatTimecode(_ t: TimeInterval, includeHours: Bool = false) -> String {
    let total = max(0, Int(t.rounded()))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 || includeHours { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

public struct SnippetWaveform: Equatable, Sendable {
    public let window: ClosedRange<TimeInterval>
    public let peaks: [Float]

    public init(window: ClosedRange<TimeInterval>, peaks: [Float]) {
        self.window = window
        self.peaks = peaks
    }

    public static func load(url: URL, window: ClosedRange<TimeInterval>, count: Int) async -> SnippetWaveform? {
        guard count > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate > 0, channels > 0 else { return nil }

        let first = max(0, AVAudioFramePosition((window.lowerBound * rate).rounded(.down)))
        let last = min(file.length, AVAudioFramePosition((window.upperBound * rate).rounded(.up)))
        let total = last - first
        guard total > 0 else { return nil }

        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        file.framePosition = first

        var peaks = [Float](repeating: 0, count: count)
        let scale = 1 / Float(channels)
        var done: AVAudioFramePosition = 0
        while done < total {
            if Task.isCancelled { return nil }
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - done))
            guard (try? file.read(into: buffer, frameCount: want)) != nil else { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var sample: Float = 0
                for c in 0..<channels { sample += data[c][i] }
                let amplitude = abs(sample * scale)
                let bin = Int((done + AVAudioFramePosition(i)) * AVAudioFramePosition(count) / total)
                if amplitude > peaks[bin] { peaks[bin] = amplitude }
            }
            done += AVAudioFramePosition(n)
        }

        if let top = peaks.max(), top > 0 {
            let norm = 1 / top
            for i in peaks.indices { peaks[i] *= norm }
        }
        return SnippetWaveform(window: window, peaks: peaks)
    }
}
