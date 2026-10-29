import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

final class MicrophoneRecorder: StreamRecorder {
    let kind = AudioStreamKind.mic
    var onEvent: ((AudioStreamKind, StreamEvent) -> Void)?
    private(set) var lastSampleTime = Date.distantPast
    private(set) var firstSampleTime: Date?
    private(set) var isCapturing = false
    var liveTranscriber: LiveStreamTranscriber?

    private let folder: URL
    private let preferredDeviceUID: String?
    private let engine = AVAudioEngine()

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var convertBuffer: AVAudioPCMBuffer?
    private var tapInstalled = false

    private var ring: AudioRingBuffer?
    private var writer: SegmentedAudioWriter?
    private var levelCounter = 0

    private var configObserver: NSObjectProtocol?
    private var pendingReconfigure: DispatchWorkItem?
    private var pendingRetry: DispatchWorkItem?
    private var retryAttempts = 0
    private let retryDelay: TimeInterval = 1.5
    private let maxRetryAttempts = 20
    private var waitingNoticeSent = false
    private var recoveryTimes: [Date] = []
    private let recoveryWindow: TimeInterval = 20
    private let maxRecoveriesInWindow = 4
    private var isStopping = false

    init(folder: URL, deviceUID: String? = nil) {
        self.folder = folder
        self.preferredDeviceUID = deviceUID
    }

    func start() throws {
        applyPreferredInputDevice()
        let ring = AudioRingBuffer(capacity: Int(outputFormat.sampleRate) * 5)
        self.ring = ring
        guard let writer = SegmentedAudioWriter(kind: .mic, folder: folder,
                                                sampleRate: outputFormat.sampleRate, channels: 1, ring: ring) else {
            throw AudioError("Could not create microphone writer.")
        }
        writer.onEvent = { [weak self] event in self?.onEvent?(.mic, event) }
        self.writer = writer

        do {
            try configureAndStart()
            isCapturing = true
        } catch let error as AudioError where error.retriable {
            scheduleRetry(after: error)
        }
        onEvent?(.mic, .formatDetermined(sampleRate: outputFormat.sampleRate, channels: 1))
        writer.start()
        observeConfigurationChanges()
        lastSampleTime = Date()
    }

    private func makeConverter(from hardwareFormat: AVAudioFormat) -> Bool {
        guard let converter = AVAudioConverter(from: hardwareFormat, to: outputFormat) else { return false }
        if hardwareFormat.channelCount > 1 {
            converter.channelMap = [0]
        }
        self.converter = converter
        if convertBuffer == nil {
            convertBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 65_536)
        }
        return convertBuffer != nil
    }

    private func installTap(format: AVAudioFormat) throws {
        try guardingAudioExceptions("Opening \(deviceLabel)") {
            let input = engine.inputNode
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            tapInstalled = true
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let ring, let converter, Int(buffer.frameLength) > 0 else { return }
        guard let out = convert(buffer, with: converter), let channel = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let now = Date()
        if firstSampleTime == nil { firstSampleTime = now }
        lastSampleTime = now
        ring.write(channel, count: n)
        liveTranscriber?.append(channel, frames: n, channels: 1, sampleRate: outputFormat.sampleRate)
        emitLevel(channel, n)
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard input.format.sampleRate == converter.inputFormat.sampleRate,
              input.format.channelCount == converter.inputFormat.channelCount,
              let out = convertBuffer else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : out
    }

    private func emitLevel(_ ptr: UnsafePointer<Float>, _ n: Int) {
        levelCounter += 1
        if levelCounter % 3 == 0 {
            onEvent?(.mic, .level(audioLevel(fromInterleaved: ptr, count: n)))
        }
    }

    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.scheduleReconfigure() }
        }
    }

    private func scheduleReconfigure() {
        guard !isStopping else { return }
        pendingReconfigure?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconfigureAfterRouteChange() }
        pendingReconfigure = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func reconfigureAfterRouteChange() {
        guard !isStopping else { return }

        let now = Date()
        recoveryTimes = recoveryTimes.filter { now.timeIntervalSince($0) < recoveryWindow }
        guard recoveryTimes.count < maxRecoveriesInWindow else {
            tearDownCapture()
            isCapturing = false
            onEvent?(.mic, .failed("\(deviceLabel) keeps changing audio routes, so microphone recording was stopped for this session. The meeting keeps recording the other side. A wired or built-in microphone avoids this (Bluetooth headsets switch to a low-quality call mode when used as a mic)."))
            return
        }
        recoveryTimes.append(now)
        attemptCapture()
    }

    /// One recovery attempt: anything transient (no input format yet, an exception from the
    /// engine while the route settles) schedules another try instead of ending the stream.
    private func attemptCapture() {
        guard !isStopping else { return }
        do {
            try reinstallCapture()
            retryAttempts = 0
            pendingRetry?.cancel()
            lastSampleTime = Date()
            if waitingNoticeSent {
                waitingNoticeSent = false
                onEvent?(.mic, .note("\(deviceLabel) is recording again."))
            }
        } catch let error as AudioError where error.retriable {
            scheduleRetry(after: error)
        } catch {
            isCapturing = false
            onEvent?(.mic, .failed("\(deviceLabel) is unavailable: \(error.localizedDescription) The meeting keeps recording the other side."))
        }
    }

    private func scheduleRetry(after error: AudioError) {
        isCapturing = false
        pendingRetry?.cancel()
        retryAttempts += 1
        guard retryAttempts <= maxRetryAttempts else {
            retryAttempts = 0
            waitingNoticeSent = false
            onEvent?(.mic, .failed("\(deviceLabel) did not come back after the audio setup changed. The meeting keeps recording the other side."))
            return
        }
        if !waitingNoticeSent {
            waitingNoticeSent = true
            onEvent?(.mic, .note("Waiting for \(deviceLabel): \(error.message)"))
        }
        let item = DispatchWorkItem { [weak self] in self?.attemptCapture() }
        pendingRetry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: item)
    }

    private func reinstallCapture() throws {
        tearDownEngine()
        applyPreferredInputDevice()
        try configureAndStart()
        isCapturing = true
    }

    /// Reads the format the input node has *now*, which is the only format a tap may use.
    private func configureAndStart() throws {
        guard let hardware = currentInputFormat() else {
            throw AudioError("the input reports no channels or sample rate yet.", retriable: true)
        }
        guard makeConverter(from: hardware) else {
            throw AudioError("Could not set up microphone audio conversion.")
        }
        try installTap(format: hardware)
        do {
            try guardingAudioExceptions("Starting \(deviceLabel)") {
                engine.prepare()
                try engine.start()
            }
        } catch let error as AudioError {
            throw error
        } catch {
            throw AudioError("the audio engine did not start (\(error.localizedDescription))", retriable: true)
        }
    }

    func pause() {
        pendingReconfigure?.cancel()
        pendingRetry?.cancel()
        isStopping = true
        try? guardingAudioExceptions("Pausing \(deviceLabel)") { engine.pause() }
        isCapturing = false
    }

    func resume() throws {
        isStopping = false
        retryAttempts = 0
        do {
            try guardingAudioExceptions("Resuming \(deviceLabel)") { try engine.start() }
            isCapturing = true
            lastSampleTime = Date()
        } catch {
            try reinstallCapture()
            lastSampleTime = Date()
        }
    }

    func restart() throws {
        retryAttempts = 0
        do {
            try reinstallCapture()
            lastSampleTime = Date()
        } catch let error as AudioError where error.retriable {
            scheduleRetry(after: error)
        }
    }

    /// A format a tap can be installed with: a real sample rate and at least one channel.
    private func currentInputFormat() -> AVAudioFormat? {
        var format: AVAudioFormat?
        try? guardingAudioExceptions("Reading the microphone format") {
            let input = engine.inputNode
            var f = input.outputFormat(forBus: 0)
            if !usable(f) {
                engine.prepare()
                f = input.outputFormat(forBus: 0)
            }
            if !usable(f) { f = input.inputFormat(forBus: 0) }
            format = usable(f) ? f : nil
        }
        return format
    }

    private func usable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func applyPreferredInputDevice() {
        guard let uid = preferredDeviceUID, let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid) else { return }
        try? guardingAudioExceptions("Selecting \(deviceLabel)") {
            guard let audioUnit = engine.inputNode.audioUnit else { return }
            var device = deviceID
            let status = AudioUnitSetProperty(audioUnit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                onEvent?(.mic, .note("\(deviceLabel) could not be selected, using the system input."))
            }
        }
    }

    /// Stops the engine and drops the tap, so the next tap is installed on a clean node.
    private func tearDownEngine() {
        try? guardingAudioExceptions("Resetting \(deviceLabel)") {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if engine.isRunning { engine.stop() }
            engine.reset()
        }
        converter = nil
    }

    private func tearDownCapture() {
        pendingReconfigure?.cancel()
        pendingRetry?.cancel()
        tearDownEngine()
    }

    func stop(completion: @escaping () -> Void) {
        isStopping = true
        tearDownCapture()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        isCapturing = false
        if let writer {
            writer.stop { completion() }
        } else {
            completion()
        }
    }

    private var deviceLabel: String {
        if let uid = preferredDeviceUID, let name = AudioDeviceEnumerator.name(forUID: uid) { return name }
        return "Your microphone"
    }
}
