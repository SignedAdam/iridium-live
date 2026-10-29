import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
public final class RecordingCoordinator {
    public enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case stopping
        case error(String)

        public var isError: Bool { if case .error = self { return true } else { return false } }
    }

    struct FinishedSession: Equatable {
        let folder: URL
        let manifest: RecordingManifest
    }

    public private(set) var state: State = .idle
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var micLevel: Float = 0
    public private(set) var systemLevel: Float = 0
    public private(set) var micAvailable = true
    public private(set) var systemAvailable = true
    public private(set) var statusMessage = ""
    private(set) var lastFinishedSession: FinishedSession?

    public var recordMic = true
    public var recordSystem = true
    public var microphoneDeviceUID: String?

    public var isRecording: Bool { state == .recording || state == .paused }
    public var canRecord: Bool { state == .idle || state.isError }

    let root: URL

    init(root: URL) { self.root = root }

    private func sessionFolder(id: String) -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var recorders: [StreamRecorder] = []
    private var manifest: RecordingManifest?
    private var sessionFolder: URL?
    private let manifestQueue = DispatchQueue(label: "com.topinit.iridium.manifest")
    private var startDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var elapsedTimer: Timer?
    private var watchdogTimer: Timer?
    private var lastPersist = Date.distantPast
    private var failureStatus = ""
    private var noteStatus = ""

    private var recoveryAttempts: [AudioStreamKind: Int] = [:]
    private var nextRecoveryTime: [AudioStreamKind: Date] = [:]
    private let staleThreshold: TimeInterval = 8
    private let maxRecoveryAttempts = 4

    func start(title: String? = nil, liveTranscribers: [AudioStreamKind: LiveStreamTranscriber] = [:]) async {
        guard canRecord else { return }
        state = .preparing
        elapsed = 0
        pausedAccumulated = 0
        micLevel = 0
        systemLevel = 0
        failureStatus = ""
        noteStatus = ""
        statusMessage = ""
        micAvailable = recordMic
        systemAvailable = recordSystem
        recoveryAttempts.removeAll()
        nextRecoveryTime.removeAll()

        if recordMic {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                micAvailable = false
                appendStatus("Microphone access denied.")
            }
        }

        let id = UUID().uuidString
        let folder = sessionFolder(id: id)
        sessionFolder = folder
        var m = RecordingManifest(sessionID: id, title: title, startedAt: Date())

        var live: [StreamRecorder] = []

        if recordMic && micAvailable {
            let recorder = MicrophoneRecorder(folder: folder, deviceUID: microphoneDeviceUID)
            recorder.onEvent = { [weak self] kind, event in
                DispatchQueue.main.async { self?.handle(kind, event) }
            }
            recorder.liveTranscriber = liveTranscribers[.mic]
            do {
                try recorder.start()
                live.append(recorder)
            } catch {
                micAvailable = false
                m.upsertStream(StreamManifest(kind: .mic, sampleRate: 0, channelCount: 0, unavailableReason: error.localizedDescription))
                appendStatus(error.localizedDescription)
            }
        }

        if recordSystem && systemAvailable {
            let recorder = SystemAudioRecorder(folder: folder)
            recorder.onEvent = { [weak self] kind, event in
                DispatchQueue.main.async { self?.handle(kind, event) }
            }
            recorder.liveTranscriber = liveTranscribers[.system]
            do {
                try recorder.start()
                live.append(recorder)
            } catch {
                systemAvailable = false
                m.upsertStream(StreamManifest(kind: .system, sampleRate: 0, channelCount: 0, unavailableReason: error.localizedDescription))
                appendStatus(error.localizedDescription)
            }
        }

        manifest = m
        persistManifest(force: true)

        guard !live.isEmpty else {
            state = .error(statusMessage.isEmpty ? "No audio sources available." : statusMessage)
            return
        }

        recorders = live
        startDate = Date()
        state = .recording
        startTimers()
    }

    func pause() {
        guard state == .recording else { return }
        if let start = startDate { pausedAccumulated += Date().timeIntervalSince(start) }
        startDate = nil
        recorders.forEach { $0.pause() }
        micLevel = 0
        systemLevel = 0
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        for recorder in recorders {
            do { try recorder.resume() } catch { appendStatus(error.localizedDescription) }
        }
        startDate = Date()
        state = .recording
    }

    @discardableResult
    func stop() async -> FinishedSession? {
        guard isRecording else { return nil }
        state = .stopping
        elapsedTimer?.invalidate(); elapsedTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil

        let toStop = recorders
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for recorder in toStop {
                group.enter()
                recorder.stop { group.leave() }
            }
            group.notify(queue: .main) { cont.resume() }
        }

        recorders.removeAll()
        var m = manifest ?? RecordingManifest(sessionID: UUID().uuidString, startedAt: Date())
        for recorder in toStop {
            guard let first = recorder.firstSampleTime, var s = m.stream(recorder.kind) else { continue }
            s.startOffset = max(0, first.timeIntervalSince(m.startedAt))
            m.upsertStream(s)
        }
        m.endedAt = Date()
        manifest = m
        if let folder = sessionFolder {
            manifestQueue.sync { try? ManifestStore.write(m, to: folder) }
        }

        micLevel = 0
        systemLevel = 0
        elapsed = m.duration
        state = .idle

        let finished = sessionFolder.map { FinishedSession(folder: $0, manifest: m) }
        lastFinishedSession = finished
        return finished
    }

    func recoverInterruptedSessions() {
        for (folder, var manifest) in ManifestStore.scanForInterruptedSessions(in: root) {
            manifest.endedAt = manifest.startedAt.addingTimeInterval(manifest.duration)
            try? ManifestStore.write(manifest, to: folder)
        }
    }

    private func handle(_ kind: AudioStreamKind, _ event: StreamEvent) {
        guard var m = manifest else { return }
        switch event {
        case let .formatDetermined(sampleRate, channels):
            if var s = m.stream(kind) {
                s.sampleRate = sampleRate
                s.channelCount = channels
                m.upsertStream(s)
            } else {
                m.upsertStream(StreamManifest(kind: kind, sampleRate: sampleRate, channelCount: channels))
            }
            manifest = m
            persistManifest(force: false)
        case let .segmentOpened(info):
            m.appendSegment(info, to: kind)
            manifest = m
            persistManifest(force: false)
        case let .segmentFinalized(info):
            m.appendSegment(info, to: kind)
            manifest = m
            persistManifest(force: true)
        case let .level(level):
            if kind == .mic { micLevel = level } else { systemLevel = level }
        case let .note(message):
            setStatus(message)
        case let .failed(message):
            if kind == .mic { micAvailable = false } else { systemAvailable = false }
            var s = m.stream(kind) ?? StreamManifest(kind: kind, sampleRate: 0, channelCount: 0)
            s.unavailableReason = message
            m.upsertStream(s)
            manifest = m
            appendStatus(message)
            persistManifest(force: true)
        }
    }

    private func startTimers() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording, let start = self.startDate else { return }
                self.elapsed = self.pausedAccumulated + Date().timeIntervalSince(start)
            }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runWatchdog() }
        }
    }

    private func runWatchdog() {
        guard state == .recording else { return }
        let now = Date()
        for recorder in recorders where recorder.isCapturing {
            let kind = recorder.kind
            let stale = now.timeIntervalSince(recorder.lastSampleTime)

            if stale < staleThreshold {
                recoveryAttempts[kind] = nil
                nextRecoveryTime[kind] = nil
                continue
            }
            if let next = nextRecoveryTime[kind], now < next { continue }

            let attempt = (recoveryAttempts[kind] ?? 0) + 1
            if attempt > maxRecoveryAttempts {
                appendStatus("\(kind.displayName) keeps dropping out, stopped recovering it. Try a wired or built in device.")
                if kind == .mic { micAvailable = false } else { systemAvailable = false }
                recorder.pause()
                recoveryAttempts[kind] = nil
                nextRecoveryTime[kind] = nil
                continue
            }
            recoveryAttempts[kind] = attempt
            nextRecoveryTime[kind] = now + min(60, pow(2, Double(attempt - 1)) * 6)
            do {
                try recorder.restart()
                appendStatus("Recovering \(kind.displayName)… (attempt \(attempt))")
            } catch {
                appendStatus("Lost \(kind.displayName): \(error.localizedDescription)")
                if kind == .mic { micAvailable = false } else { systemAvailable = false }
            }
        }
    }

    /// Lost streams stay on the status line; the recovery note is replaced each time, so a long
    /// meeting does not pile up old attempts.
    private func appendStatus(_ message: String) {
        guard !failureStatus.contains(message) else { return }
        failureStatus = failureStatus.isEmpty ? message : failureStatus + " " + message
        composeStatus()
    }

    private func setStatus(_ message: String) {
        noteStatus = message
        composeStatus()
    }

    private func composeStatus() {
        statusMessage = [failureStatus, noteStatus].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func persistManifest(force: Bool) {
        guard let m = manifest, let folder = sessionFolder else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastPersist) < 1.5 { return }
        lastPersist = now
        manifestQueue.async { try? ManifestStore.write(m, to: folder) }
    }
}
