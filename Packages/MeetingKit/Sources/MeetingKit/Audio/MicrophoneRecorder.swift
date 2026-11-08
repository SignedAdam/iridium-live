import Foundation
import AVFoundation
import CoreAudio

/// Records one microphone through a Core Audio IOProc on that device alone. AVAudioEngine's input
/// node runs on an aggregate of the default input and the default output and follows both, so a
/// Bluetooth headset that became the default was pulled into call mode mid-call (the call froze and
/// its audio moved to the speakers) and the chosen microphone was dropped for the rest of the meeting.
/// Here the chosen microphone stays chosen; the default input is recorded only when none is chosen
/// or the chosen one is not connected, and the recorder moves back as soon as it is. Every Core Audio
/// call runs on `control`, never the main thread: they can block for minutes while a Bluetooth device
/// changes mode.
final class MicrophoneRecorder: StreamRecorder {
    let kind = AudioStreamKind.mic
    var onEvent: ((AudioStreamKind, StreamEvent) -> Void)?
    private(set) var lastSampleTime = Date.distantPast
    private(set) var firstSampleTime: Date?
    private(set) var isCapturing = false
    var liveTranscriber: LiveStreamTranscriber?

    private let folder: URL
    private let preferredDeviceUID: String?
    private let control = DispatchQueue(label: "com.topinit.iridium.mic.control")
    private let ioQueue = DispatchQueue(label: "com.topinit.iridium.mic.ioproc", qos: .userInitiated)
    private let sampleRate = 48_000.0
    private static let chunk = 16_384
    private static let framesPerLevel = 12_288

    private var ring: AudioRingBuffer?
    private var writer: SegmentedAudioWriter?
    private let mono = UnsafeMutableBufferPointer<Float>.allocate(capacity: MicrophoneRecorder.chunk)
    private var framesSinceLevel = 0

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioPCMBuffer?
    private var converterOutput: AVAudioPCMBuffer?

    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice = AudioDeviceID(kAudioObjectUnknown)
    private var pending: DispatchWorkItem?
    private var retryAttempts = 0
    private let retryDelay: TimeInterval = 1.5
    private let settleDelay: TimeInterval = 0.3
    private let maxRetryAttempts = 20
    private var waiting = false
    private var paused = false
    private var finished = false

    private static let systemSelectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    private static let deviceAddresses = [
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    init(folder: URL, deviceUID: String? = nil) {
        self.folder = folder
        self.preferredDeviceUID = deviceUID
    }

    deinit { mono.deallocate() }

    func start() throws {
        let ring = AudioRingBuffer(capacity: Int(sampleRate) * 5)
        self.ring = ring
        guard let writer = SegmentedAudioWriter(kind: .mic, folder: folder, sampleRate: sampleRate, channels: 1, ring: ring) else {
            throw AudioError("Could not create microphone writer.")
        }
        writer.onEvent = { [weak self] event in self?.onEvent?(.mic, event) }
        self.writer = writer
        onEvent?(.mic, .formatDetermined(sampleRate: sampleRate, channels: 1))
        writer.start()
        lastSampleTime = Date()
        control.async { [self] in
            listenToSystem()
            follow()
        }
    }

    func pause() {
        isCapturing = false
        control.async { [self] in
            paused = true
            pending?.cancel()
            close()
        }
    }

    func resume() throws {
        lastSampleTime = Date()
        control.async { [self] in
            paused = false
            follow()
        }
    }

    func restart() throws {
        lastSampleTime = Date()
        control.async { [self] in
            retryAttempts = 0
            close()
            follow()
        }
    }

    func stop(completion: @escaping () -> Void) {
        isCapturing = false
        control.async { [self] in
            finished = true
            pending?.cancel()
            close()
            unlistenToSystem()
            if let writer {
                writer.stop { completion() }
            } else {
                completion()
            }
        }
    }

    /// The chosen microphone while it is connected, else the default input.
    private func target() -> AudioDeviceID? {
        if let uid = preferredDeviceUID, let id = AudioDeviceEnumerator.deviceID(forUID: uid) { return id }
        return AudioDeviceEnumerator.defaultInputDeviceID()
    }

    private func follow() {
        guard !finished, !paused else { return }
        guard let next = target() else {
            close()
            wait("no microphone is connected")
            return
        }
        if next == device, ioProcID != nil { return }
        open(next)
    }

    private func open(_ id: AudioDeviceID) {
        close()
        device = id
        let name = AudioDeviceEnumerator.name(of: id) ?? "The microphone"
        guard let rate = AudioDeviceEnumerator.nominalSampleRate(of: id) else {
            return retry("\(name) reports no sample rate yet")
        }
        guard prepareConversion(from: rate) else { return retry("\(name) has an unsupported sample rate (\(Int(rate)) Hz)") }
        listen(to: id)
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, id, ioQueue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard created == noErr, let procID else { return retry("\(name) could not be opened (code \(created))") }
        ioProcID = procID
        let started = AudioDeviceStart(id, procID)
        guard started == noErr else { return retry("\(name) did not start (code \(started))") }
        isCapturing = true
        lastSampleTime = Date()
        retryAttempts = 0
        if let uid = preferredDeviceUID, AudioDeviceEnumerator.uid(of: id) != uid {
            onEvent?(.mic, .note("The chosen microphone is not connected, so \(name) is recorded until it is."))
        } else if waiting {
            onEvent?(.mic, .note("\(name) is recording again."))
        }
        waiting = false
    }

    /// Stops and forgets the IOProc, then drains its queue, so the conversion state is never
    /// changed under a callback still in flight.
    private func close() {
        if let procID = ioProcID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            ioProcID = nil
            ioQueue.sync {}
        }
        unlistenToDevice()
        device = AudioDeviceID(kAudioObjectUnknown)
        isCapturing = false
    }

    private func wait(_ reason: String) {
        isCapturing = false
        guard !waiting else { return }
        waiting = true
        onEvent?(.mic, .note("Waiting for the microphone: \(reason)."))
    }

    private func retry(_ reason: String) {
        close()
        retryAttempts += 1
        guard retryAttempts <= maxRetryAttempts else {
            finished = true
            unlistenToSystem()
            onEvent?(.mic, .failed("\(reason), so the microphone is not recorded. The meeting keeps recording the other side."))
            return
        }
        wait(reason)
        schedule(after: retryDelay)
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.follow() }
        pending = item
        control.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func prepareConversion(from rate: Double) -> Bool {
        guard rate != sampleRate else {
            converter = nil
            converterInput = nil
            converterOutput = nil
            return true
        }
        guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to),
              let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(Self.chunk)),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount((Double(Self.chunk) * sampleRate / rate).rounded(.up)) + 1024)
        else { return false }
        self.converter = converter
        converterInput = input
        converterOutput = output
        return true
    }

    /// Channel 0 of the device's first input stream, at 48 kHz.
    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
        let stride = Int(first.mNumberChannels)
        let samples = data.assumingMemoryBound(to: Float.self)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
        var offset = 0
        while offset < frames {
            let n = min(Self.chunk, frames - offset)
            for i in 0..<n { mono[i] = samples[(offset + i) * stride] }
            consume(n)
            offset += n
        }
    }

    private func consume(_ frames: Int) {
        guard let base = mono.baseAddress else { return }
        guard let converter, let input = converterInput, let output = converterOutput,
              let inChannel = input.floatChannelData?[0] else {
            write(base, frames)
            return
        }
        inChannel.update(from: base, count: frames)
        input.frameLength = AVAudioFrameCount(frames)
        output.frameLength = 0
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let outChannel = output.floatChannelData?[0] else { return }
        write(outChannel, Int(output.frameLength))
    }

    private func write(_ samples: UnsafePointer<Float>, _ frames: Int) {
        guard let ring, frames > 0 else { return }
        let now = Date()
        if firstSampleTime == nil { firstSampleTime = now }
        lastSampleTime = now
        ring.write(samples, count: frames)
        liveTranscriber?.append(samples, frames: frames, channels: 1, sampleRate: sampleRate)
        framesSinceLevel += frames
        if framesSinceLevel >= Self.framesPerLevel {
            framesSinceLevel = 0
            onEvent?(.mic, .level(audioLevel(fromInterleaved: samples, count: frames)))
        }
    }

    private func listenToSystem() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.finished else { return }
            self.schedule(after: self.settleDelay)
        }
        systemListener = block
        for selector in Self.systemSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        }
    }

    private func unlistenToSystem() {
        guard let block = systemListener else { return }
        for selector in Self.systemSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        }
        systemListener = nil
    }

    /// A rate or channel change, or the device going away, reopens from scratch.
    private func listen(to id: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.finished else { return }
            self.close()
            self.schedule(after: self.settleDelay)
        }
        deviceListener = block
        listenedDevice = id
        for (selector, scope) in Self.deviceAddresses {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &address, control, block)
        }
    }

    private func unlistenToDevice() {
        guard let block = deviceListener else { return }
        for (selector, scope) in Self.deviceAddresses {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(listenedDevice, &address, control, block)
        }
        deviceListener = nil
        listenedDevice = AudioDeviceID(kAudioObjectUnknown)
    }
}
