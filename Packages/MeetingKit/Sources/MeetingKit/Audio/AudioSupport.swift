import Foundation

struct AudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum StreamEvent {
    case formatDetermined(sampleRate: Double, channels: Int)
    case segmentOpened(AudioSegmentInfo)
    case segmentFinalized(AudioSegmentInfo)
    case level(Float)
    case failed(String)
}

protocol StreamRecorder: AnyObject {
    var kind: AudioStreamKind { get }
    var onEvent: ((AudioStreamKind, StreamEvent) -> Void)? { get set }
    var lastSampleTime: Date { get }
    var firstSampleTime: Date? { get }
    var isCapturing: Bool { get }

    func start() throws
    func pause()
    func resume() throws
    func restart() throws
    func stop(completion: @escaping () -> Void)
}

func audioLevel(fromInterleaved ptr: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    var sum: Float = 0
    var i = 0
    while i < count {
        let s = ptr[i]
        sum += s * s
        i += 1
    }
    let rms = (sum / Float(count)).squareRoot()
    return min(1, rms * 6)
}
