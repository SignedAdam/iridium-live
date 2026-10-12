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

    private var ring: AudioRingBuffer?
    private var writer: SegmentedAudioWriter?
    private var levelCounter = 0

    private var configObserver: NSObjectProtocol?
    private var pendingReconfigure: DispatchWorkItem?
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

        try configureAndStart()
        onEvent?(.mic, .formatDetermined(sampleRate: outputFormat.sampleRate, channels: 1))
        writer.start()
        observeConfigurationChanges()
        isCapturing = true
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

    private func installTap(format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
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
        guard let out = convertBuffer else { return nil }
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
        guard isCapturing, !isStopping else { return }
        pendingReconfigure?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconfigureAfterRouteChange() }
        pendingReconfigure = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func reconfigureAfterRouteChange() {
        guard isCapturing, !isStopping else { return }

        let now = Date()
        recoveryTimes = recoveryTimes.filter { now.timeIntervalSince($0) < recoveryWindow }
        guard recoveryTimes.count < maxRecoveriesInWindow else {
            tearDownCapture()
            isCapturing = false
            onEvent?(.mic, .failed("\(deviceLabel) keeps changing audio routes, so microphone recording was stopped for this session. A wired or built-in microphone avoids this (Bluetooth headsets switch to a low-quality call mode when used as a mic)."))
            return
        }
        recoveryTimes.append(now)

        do {
            try reinstallCapture()
            lastSampleTime = Date()
        } catch {
            isCapturing = false
            onEvent?(.mic, .failed("Microphone unavailable after a route change: \(error.localizedDescription)"))
        }
    }

    private func reinstallCapture() throws {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        applyPreferredInputDevice()
        try configureAndStart()
        isCapturing = true
    }

    private func configureAndStart() throws {
        let hw = try captureFormat()
        guard makeConverter(from: hw) else {
            throw AudioError("Could not set up microphone audio conversion.")
        }
        installTap(format: hw)
        engine.prepare()
        try engine.start()
    }

    func pause() {
        isStopping = true
        pendingReconfigure?.cancel()
        engine.pause()
        isCapturing = false
    }

    func resume() throws {
        isStopping = false
        try engine.start()
        isCapturing = true
        lastSampleTime = Date()
    }

    func restart() throws {
        try reinstallCapture()
        lastSampleTime = Date()
    }

    private func captureFormat() throws -> AVAudioFormat {
        let input = engine.inputNode
        var f = input.outputFormat(forBus: 0)
        if f.sampleRate <= 0 {
            engine.prepare()
            f = input.outputFormat(forBus: 0)
        }
        if f.sampleRate <= 0 { f = input.inputFormat(forBus: 0) }
        guard f.sampleRate > 0 else {
            throw AudioError("Microphone is unavailable (no input format). Check the microphone permission.")
        }
        return f
    }

    private func applyPreferredInputDevice() {
        guard let uid = preferredDeviceUID,
              let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid),
              let audioUnit = engine.inputNode.audioUnit else { return }
        var device = deviceID
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0,
                             &device,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func tearDownCapture() {
        pendingReconfigure?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    func stop(completion: @escaping () -> Void) {
        isStopping = true
        pendingReconfigure?.cancel()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
