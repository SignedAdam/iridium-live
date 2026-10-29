import Foundation
import CoreAudio
import AVFoundation

public final class SystemAudioRecorder: StreamRecorder {
    let kind = AudioStreamKind.system
    var onEvent: ((AudioStreamKind, StreamEvent) -> Void)?
    private(set) var lastSampleTime = Date.distantPast
    private(set) var firstSampleTime: Date?
    private(set) var isCapturing = false
    var liveTranscriber: LiveStreamTranscriber?

    private let folder: URL
    private let ioQueue = DispatchQueue(label: "com.topinit.iridium.system.ioproc", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    private var ring: AudioRingBuffer?
    private var writer: SegmentedAudioWriter?
    private var sampleRate: Double = 0
    private var channels = 0
    private var interleaved = true
    private var interleaveScratch: UnsafeMutableBufferPointer<Float>?
    private var levelCounter = 0

    init(folder: URL) { self.folder = folder }

    public static func hasSystemAudioPermission() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Iridium Live Permission Probe"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { return false }
        AudioHardwareDestroyProcessTap(tap)
        return true
    }

    func start() throws {
        try setupCoreAudio()
        let ring = AudioRingBuffer(capacity: max(1, Int(sampleRate)) * max(1, channels) * 5)
        self.ring = ring
        guard let writer = SegmentedAudioWriter(kind: .system, folder: folder,
                                                sampleRate: sampleRate, channels: channels, ring: ring) else {
            cleanupCoreAudio()
            throw AudioError("Could not create system-audio writer.")
        }
        writer.onEvent = { [weak self] event in self?.onEvent?(.system, event) }
        self.writer = writer
        onEvent?(.system, .formatDetermined(sampleRate: sampleRate, channels: channels))
        writer.start()
        try startIOProc()
        isCapturing = true
    }

    private func setupCoreAudio() throws {
        tapUUID = UUID()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = tapUUID
        desc.name = "Iridium Live System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw AudioError("System audio is unavailable (tap creation failed, code \(status)). Allow Iridium Live to record audio in System Settings, Privacy and Security.")
        }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            cleanupCoreAudio()
            throw AudioError("Could not read system-audio format (code \(status)).")
        }
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        let aggUID = UUID().uuidString
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Iridium Live System Capture",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg)
        guard status == noErr, agg != kAudioObjectUnknown else {
            cleanupCoreAudio()
            throw AudioError("Could not create system-audio aggregate device (code \(status)).")
        }
        aggregateID = agg

        if !interleaved {
            if let old = interleaveScratch { old.deallocate() }
            interleaveScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 65_536 * channels)
        }
    }

    private func startIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard status == noErr, let procID else {
            cleanupCoreAudio()
            throw AudioError("Could not create system-audio IOProc (code \(status)).")
        }
        ioProcID = procID
        let started = AudioDeviceStart(aggregateID, procID)
        guard started == noErr else {
            cleanupCoreAudio()
            throw AudioError("Could not start system-audio device (code \(started)).")
        }
    }

    private func handle(_ ablPtr: UnsafePointer<AudioBufferList>) {
        guard let ring, channels > 0 else { return }
        let now = Date()
        if firstSampleTime == nil { firstSampleTime = now }
        lastSampleTime = now
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
        guard abl.count > 0 else { return }

        if interleaved {
            guard let data = abl[0].mData else { return }
            let floatCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard floatCount > 0 else { return }
            let ptr = data.assumingMemoryBound(to: Float.self)
            ring.write(ptr, count: floatCount)
            liveTranscriber?.append(ptr, frames: floatCount / channels, channels: channels, sampleRate: sampleRate)
            emitLevel(ptr, floatCount)
        } else {
            guard let scratch = interleaveScratch, let base = scratch.baseAddress,
                  abl.count >= channels else { return }
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let maxFrames = scratch.count / channels
            let n = min(frames, maxFrames)
            guard n > 0 else { return }
            for c in 0..<channels {
                guard let cd = abl[c].mData else { continue }
                let src = cd.assumingMemoryBound(to: Float.self)
                var f = 0
                while f < n {
                    scratch[f * channels + c] = src[f]
                    f += 1
                }
            }
            ring.write(base, count: n * channels)
            liveTranscriber?.append(base, frames: n, channels: channels, sampleRate: sampleRate)
            emitLevel(base, n * channels)
        }
    }

    private func emitLevel(_ ptr: UnsafePointer<Float>, _ n: Int) {
        levelCounter += 1
        if levelCounter % 4 == 0 {
            onEvent?(.system, .level(audioLevel(fromInterleaved: ptr, count: n)))
        }
    }

    func pause() {
        if let p = ioProcID { AudioDeviceStop(aggregateID, p) }
        isCapturing = false
    }

    func resume() throws {
        guard let p = ioProcID else { throw AudioError("System audio not initialized.") }
        let s = AudioDeviceStart(aggregateID, p)
        guard s == noErr else { throw AudioError("Could not resume system audio (code \(s)).") }
        isCapturing = true
        lastSampleTime = Date()
    }

    /// Rebuilds the tap and the aggregate device. A failure leaves nothing running, so the next
    /// watchdog attempt starts from a clean state instead of a half-built device. The writer was
    /// opened for one format, so a tap that comes back with another one is refused rather than
    /// written at the wrong speed.
    func restart() throws {
        isCapturing = false
        let wasRate = sampleRate
        let wasChannels = channels
        cleanupCoreAudio()
        sampleRate = 0
        channels = 0
        try setupCoreAudio()
        guard wasRate == 0 || (sampleRate == wasRate && channels == wasChannels) else {
            cleanupCoreAudio()
            throw AudioError("System audio changed to \(Int(sampleRate)) Hz mid meeting, so it is no longer recorded. The microphone keeps recording.")
        }
        try startIOProc()
        isCapturing = true
        lastSampleTime = Date()
    }

    func stop(completion: @escaping () -> Void) {
        cleanupCoreAudio()
        isCapturing = false
        if let writer {
            writer.stop { completion() }
        } else {
            completion()
        }
    }

    private func teardownCoreAudioOnly() {
        if let p = ioProcID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func cleanupCoreAudio() {
        teardownCoreAudioOnly()
        if let s = interleaveScratch {
            s.deallocate()
            interleaveScratch = nil
        }
    }
}
