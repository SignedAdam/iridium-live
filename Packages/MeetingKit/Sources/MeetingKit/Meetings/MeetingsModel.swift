import Foundation
import Observation

@MainActor
@Observable
public final class MeetingsModel {
    public let coordinator: RecordingCoordinator
    public let live = LiveTranscriptModel()
    public let player = MeetingPlayer()

    public private(set) var meetings: [Meeting] = []
    public var selectedID: UUID?
    public private(set) var progress: [UUID: Double] = [:]
    public private(set) var slow: Set<UUID> = []
    public private(set) var summarizing: Set<UUID> = []
    public private(set) var chatting: Set<UUID> = []
    public private(set) var inputDevices: [AudioInputDevice] = AudioDeviceEnumerator.inputDevices()
    public private(set) var playerMeetingID: UUID?
    public var lastError: String?

    public var isRecording: Bool { coordinator.isRecording }
    public var canSummarize: Bool {
        let c = config()
        return c.hasKey(c.summaryProvider == "anthropic" ? "anthropic" : "openrouter")
    }

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let config: @MainActor () -> MeetingConfig
    @ObservationIgnored private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var liveOtherNames: [UUID: String] = [:]
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private let slowWarningSeconds: UInt64 = 90

    public init(root: URL, config: @escaping @MainActor () -> MeetingConfig) {
        self.store = MeetingStore(root: root)
        self.config = config
        self.coordinator = RecordingCoordinator(root: root)
        let c = config()
        coordinator.recordMic = c.recordMic
        coordinator.recordSystem = c.recordSystem
        coordinator.microphoneDeviceUID = c.microphoneUID
        AudioDeviceEnumerator.observeDeviceChanges { [weak self] in
            MainActor.assumeIsolated { self?.inputDevices = AudioDeviceEnumerator.inputDevices() }
        }
        meetings = store.load()
        coordinator.recoverInterruptedSessions()
        importOrphanedSessions()
        resetStuckTranscriptions()
    }

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    public func folderURL(_ id: UUID) -> URL? { meeting(id).map { store.folder($0) } }

    public func engineName(_ id: String?) -> String { EngineFactory.name(for: id) }

    private func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        store.save(meetings[index])
    }

    private func sort() { meetings.sort { $0.startedAt > $1.startedAt } }

    private func importOrphanedSessions() {
        let known = Set(meetings.map(\.folderName))
        var imported = false
        for name in store.folderNames() where !known.contains(name) {
            let folder = store.root.appendingPathComponent(name, isDirectory: true)
            guard let manifest = try? ManifestStore.read(from: folder), manifest.duration > 0.3 else { continue }
            let meeting = Meeting(from: RecordingCoordinator.FinishedSession(folder: folder, manifest: manifest))
            meetings.append(meeting)
            store.save(meeting)
            imported = true
        }
        if imported { sort() }
    }

    private func resetStuckTranscriptions() {
        for meeting in meetings where meeting.state == .running {
            update(meeting.id) {
                $0.state = .failed
                $0.error = "Transcription was interrupted. Retry to run it again."
            }
        }
    }

    public func startRecording() async {
        let c = config()
        coordinator.recordMic = c.recordMic
        coordinator.recordSystem = c.recordSystem
        coordinator.microphoneDeviceUID = c.microphoneUID
        guard coordinator.canRecord else { return }
        var kinds: [AudioStreamKind] = []
        if coordinator.recordMic { kinds.append(.mic) }
        if coordinator.recordSystem { kinds.append(.system) }
        let liveTranscribers = live.begin(kinds: kinds, languageHint: c.languageHint)
        await coordinator.start(liveTranscribers: liveTranscribers)
        if !coordinator.isRecording { live.cancel() }
    }

    public func stopRecording() async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        guard let finished = await coordinator.stop() else { return }
        guard finished.manifest.duration > 0.3 else {
            live.end(meetingID: nil)
            try? FileManager.default.removeItem(at: finished.folder)
            return
        }
        let meeting = Meeting(from: finished)
        live.end(meetingID: meeting.id)
        if let name = live.namedOther { liveOtherNames[meeting.id] = name }
        meetings.append(meeting)
        sort()
        if !store.save(meeting) {
            lastError = "Your audio is saved, but writing the meeting entry failed."
        }
        transcribe(meeting.id)
    }

    public func toggleRecording() {
        Task {
            switch coordinator.state {
            case .idle, .error: await startRecording()
            case .recording, .paused: await stopRecording()
            default: break
            }
        }
    }

    public func pause() { coordinator.pause() }

    public func resume() { coordinator.resume() }

    public func transcribe(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        transcriptionTasks[id]?.cancel()

        let c = config()
        let engine = EngineFactory.resolvedEngine(for: c)
        let options = TranscriptionOptions(languageHint: c.languageHint, diarize: true)
        let folder = store.folder(meeting)

        update(id) {
            $0.state = .running
            $0.error = nil
            $0.engineID = engine.id
        }
        progress[id] = 0
        slow.remove(id)

        let warn = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: (self?.slowWarningSeconds ?? 90) * 1_000_000_000)
            guard let self, self.transcriptionTasks[id] != nil else { return }
            self.slow.insert(id)
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                warn.cancel()
                self.slow.remove(id)
                self.progress[id] = nil
                self.transcriptionTasks[id] = nil
            }
            do {
                let manifest = try ManifestStore.read(from: folder)
                var pipeline = TranscriptionPipeline()
                if engine.isLocal, !engine.supportsDiarization {
                    pipeline.systemDiarizer = FluidAudioDiarizer()
                }
                let transcript = try await pipeline.transcribe(
                    manifest: manifest, folder: folder, engine: engine, options: options,
                    progress: { p in Task { @MainActor in self.progress[id] = p } }
                )
                if Task.isCancelled { return }
                self.update(id) {
                    $0.transcript = transcript
                    $0.state = .done
                    $0.error = nil
                }
                self.applyLiveOtherName(to: id)
                if IntelligenceFactory.provider(for: self.config()) != nil {
                    await self.summarizeMeeting(id)
                }
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                self.update(id) {
                    $0.state = .failed
                    $0.error = error.localizedDescription
                }
                self.lastError = error.localizedDescription
            }
        }
        transcriptionTasks[id] = task
    }

    public func cancelTranscription(_ id: UUID) {
        transcriptionTasks[id]?.cancel()
        transcriptionTasks[id] = nil
        progress[id] = nil
        slow.remove(id)
        update(id) {
            $0.state = .failed
            $0.error = "Transcription cancelled. Your audio is saved, retry when you want."
        }
    }

    public func summarize(_ id: UUID) {
        Task { await summarizeMeeting(id) }
    }

    private func summarizeMeeting(_ id: UUID) async {
        guard let provider = IntelligenceFactory.provider(for: config()),
              let meeting = meeting(id),
              let transcript = meeting.resolvedTranscript, !transcript.turns.isEmpty else { return }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            let summary = try await provider.summarize(transcript: transcript, context: meeting.title)
            update(id) { $0.summary = summary }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func sendChat(_ text: String, to id: UUID) {
        Task { await runChat(text, to: id) }
    }

    private func runChat(_ text: String, to id: UUID) async {
        guard let provider = IntelligenceFactory.provider(for: config()),
              let meeting = meeting(id),
              let transcript = meeting.resolvedTranscript else { return }
        var history = meeting.chat
        history.append(ChatMessage(role: .user, text: text))
        update(id) { $0.chat = history }
        chatting.insert(id)
        defer { chatting.remove(id) }
        do {
            let reply = try await provider.chat(history: history, transcript: transcript)
            history.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            history.append(ChatMessage(role: .assistant, text: error.localizedDescription))
        }
        update(id) { $0.chat = history }
    }

    public func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    public func setArchived(_ id: UUID, _ archived: Bool) {
        update(id) { $0.isArchived = archived }
    }

    public func delete(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        transcriptionTasks[id]?.cancel()
        transcriptionTasks[id] = nil
        if selectedID == id { selectedID = nil }
        if playerMeetingID == id {
            player.stop()
            player.loadedURL = nil
            playerMeetingID = nil
        }
        store.delete(meeting)
        meetings.removeAll { $0.id == id }
    }

    public func renameSpeaker(_ speakerID: String, to name: String, in id: UUID) {
        update(id) {
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                $0.speakerNames[speakerID] = nil
            } else {
                $0.speakerNames[speakerID] = name
            }
        }
    }

    public func mergeSpeaker(_ source: String, into target: String, in id: UUID) {
        update(id) {
            guard var transcript = $0.transcript else { return }
            transcript.mergeSpeaker(source, into: target)
            $0.transcript = transcript
            $0.speakerNames[source] = nil
        }
    }

    public func editTranscript(_ id: UUID, _ edit: (inout Transcript) -> Void) {
        update(id) {
            guard var transcript = $0.transcript else { return }
            edit(&transcript)
            $0.transcript = transcript
        }
    }

    public func toggleActionItem(_ itemID: UUID, in id: UUID) {
        update(id) {
            guard var summary = $0.summary,
                  let i = summary.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            summary.actionItems[i].done.toggle()
            $0.summary = summary
        }
    }

    private func applyLiveOtherName(to id: UUID) {
        let liveName = live.meetingID == id ? live.namedOther : nil
        guard let name = liveName ?? liveOtherNames[id],
              let meeting = meeting(id),
              let transcript = meeting.transcript else { return }
        liveOtherNames[id] = nil
        let others = transcript.speakerIDs.filter { $0 != AudioStreamKind.mic.defaultSpeakerLabel }
        guard others.count == 1, let other = others.first,
              meeting.speakerNames[other] == nil else { return }
        renameSpeaker(other, to: name, in: id)
    }

    public func export(_ id: UUID, as format: TranscriptExportFormat) -> (text: String, fileName: String)? {
        guard let meeting = meeting(id), let transcript = meeting.resolvedTranscript else { return nil }
        let text = TranscriptExporter.export(transcript, as: format, title: meeting.title,
                                             date: meeting.startedAt, summary: meeting.summary)
        let name = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return (text, "\(name).\(format.fileExtension)")
    }

    public func copyText(_ id: UUID) -> String? {
        guard let meeting = meeting(id), let t = meeting.resolvedTranscript else { return nil }
        let clock = DateFormatter()
        clock.locale = .current
        clock.dateFormat = "h:mm:ss a"
        let showHours = (t.turns.last?.start ?? 0) >= 3600
        var lines = [meeting.title, meeting.startedAt.formatted(date: .abbreviated, time: .shortened), ""]
        for turn in t.turns {
            let rel = formatTimecode(turn.start, includeHours: showHours)
            let wall = clock.string(from: meeting.startedAt.addingTimeInterval(turn.start))
            lines.append("[\(rel) \(wall)] \(t.name(for: turn.speakerID)): \(turn.text)")
        }
        return lines.joined(separator: "\n")
    }

    public func preparePlayer(for id: UUID) async {
        guard let meeting = meeting(id) else { return }
        if playerMeetingID == id, player.loadedURL != nil { return }
        let folder = store.folder(meeting)
        let url: URL? = await Task.detached(priority: .utility) {
            guard let manifest = try? ManifestStore.read(from: folder) else { return nil }
            return try? PlaybackPreparer().playbackURL(folder: folder, manifest: manifest)
        }.value
        guard let url else { return }
        player.load(url)
        playerMeetingID = id
    }

    public func importLegacy(from oldSupport: URL) -> Int {
        let imported = LegacyImport.run(from: oldSupport, into: store)
        if imported > 0 {
            meetings = store.load()
        }
        return imported
    }
}
