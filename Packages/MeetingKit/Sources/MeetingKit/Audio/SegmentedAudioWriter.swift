import Foundation
import AVFoundation

final class SegmentedAudioWriter {
    let kind: AudioStreamKind

    private let folder: URL
    private let format: AVAudioFormat
    private let sampleRate: Double
    private let channels: Int
    private let segmentDuration: TimeInterval
    private let ring: AudioRingBuffer
    private let queue: DispatchQueue
    private let pcmBuffer: AVAudioPCMBuffer
    private let chunkFrames: AVAudioFrameCount = 8192

    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var nextIndex = 0
    private var totalFrames: AVAudioFramePosition = 0

    private struct OpenSegment {
        var index: Int
        var name: String
        var startFrame: AVAudioFramePosition
        var frames: AVAudioFramePosition
    }
    private var open: OpenSegment?

    var onEvent: ((StreamEvent) -> Void)?

    init?(kind: AudioStreamKind, folder: URL, sampleRate: Double, channels: Int, ring: AudioRingBuffer, segmentDuration: TimeInterval = 45) {
        guard channels > 0, sampleRate > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: true),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames)
        else { return nil }
        self.kind = kind
        self.folder = folder
        self.format = fmt
        self.sampleRate = sampleRate
        self.channels = channels
        self.segmentDuration = segmentDuration
        self.ring = ring
        self.pcmBuffer = buf
        self.queue = DispatchQueue(label: "com.topinit.iridium.writer.\(kind.rawValue)", qos: .utility)
    }

    func start() {
        queue.async {
            self.openSegment()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.drain() }
            t.resume()
            self.timer = t
        }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.drain()
            self.finalizeOpen()
            completion()
        }
    }

    private func openSegment() {
        let index = nextIndex
        nextIndex += 1
        let name = String(format: "%@-%03d.caf", kind.fileBaseName, index)
        let url = folder.appendingPathComponent(name)
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: true)
            open = OpenSegment(index: index, name: name, startFrame: totalFrames, frames: 0)
            onEvent?(.segmentOpened(AudioSegmentInfo(index: index, fileName: name,
                                                     startTime: Double(totalFrames) / sampleRate,
                                                     duration: 0, finalized: false)))
        } catch {
            onEvent?(.failed("Could not open segment: \(error.localizedDescription)"))
        }
    }

    private func finalizeOpen() {
        guard let o = open else { return }
        file = nil
        let info = AudioSegmentInfo(index: o.index, fileName: o.name,
                                    startTime: Double(o.startFrame) / sampleRate,
                                    duration: Double(o.frames) / sampleRate, finalized: true)
        open = nil
        onEvent?(.segmentFinalized(info))
    }

    private func rotate() {
        finalizeOpen()
        openSegment()
    }

    private func drain() {
        guard file != nil else { return }
        let cap = Int(chunkFrames) * channels
        guard let raw = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)[0].mData else { return }
        let dst = raw.assumingMemoryBound(to: Float.self)
        while true {
            guard let f = file else { return }
            let got = ring.read(into: dst, maxCount: cap)
            if got == 0 { return }
            let frames = got / channels
            if frames == 0 { return }
            pcmBuffer.frameLength = AVAudioFrameCount(frames)
            do {
                try f.write(from: pcmBuffer)
            } catch {
                onEvent?(.failed("Write failed: \(error.localizedDescription)"))
                return
            }
            if var o = open {
                o.frames += AVAudioFramePosition(frames)
                open = o
            }
            totalFrames += AVAudioFramePosition(frames)
            if let o = open, Double(o.frames) / sampleRate >= segmentDuration {
                rotate()
            }
            if got < cap { return }
        }
    }
}
