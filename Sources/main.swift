import AppKit
@preconcurrency import MeetingKit

signal(SIGPIPE, SIG_IGN)
MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--check") {
        print(AppResources.report())
        exit(0)
    }
    let wav = arguments.firstIndex(of: "--wav").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    CTFontManagerRegisterFontsForURL(AppResources.font as CFURL, .process, nil)
    Setup.clearStaleAccessibility()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu(in: app)
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
    let model = AppModel()
    Look.shared.apply(model.settings)
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Iridium Live")
    Migration.carryOver(to: support)
    let library = NotesLibrary(directory: support)
    let history = HistoryStore(directory: support)
    let usage = UsageLog(directory: support)
    model.history = history.load()
    let meetings = MeetingsModel(root: support.appendingPathComponent("Meetings")) {
        MeetingConfig(engineID: model.settings.meetingEngine,
                      languageHint: model.settings.meetingLanguage,
                      recordMic: model.settings.meetingMic,
                      recordSystem: model.settings.meetingSystem,
                      microphoneUID: model.settings.meetingMicrophone,
                      autoTranscribe: model.settings.meetingAutoTranscribe,
                      liveTranscript: model.settings.meetingLiveTranscript,
                      summaryProvider: model.settings.summaryProvider,
                      summaryModel: model.settings.summaryModel,
                      hasKey: { Keychain.shared.stored().contains($0) },
                      key: { Keychain.shared.values()[$0] })
    }
    model.meetings = meetings
    let notes = NotesEditor(model: model, library: library)
    let captions = Captions(settings: model.settings)
    let keys = KeyboardSink()
    keys.pasteApps = Set(model.settings.pasteApps)
    let typist = Typist(sink: keys)
    let control = ControlWindowController(model: model, notes: notes, screen: screen)
    let hotkeys = HotkeyMonitor()
    let idle = IdleUnloader()
    let recordings = support.appendingPathComponent("Recordings")
    let intents = TakeIntents()
    if TakeRecovery.run(journal: TakeJournal(directory: recordings), history: &model.history, store: history) > 0 {
        model.show(notice: "Some recordings did not finish. They are in History.")
    }
    let dock = ChatDock(model: model, directory: support)
    let statusItem = StatusItem(model: model)
    model.chatApps = dock.apps
    model.onEditChatApps = { dock.editProfiles(on: control.window.screen ?? screen) }
    model.onOpenMeetings = { select in
        MeetingsWindow.show(on: control.window.screen ?? screen, model: model, meetings: meetings, select: select)
    }
    model.onOpenCorrections = { entry in
        CorrectionsWindow.show(on: control.window.screen ?? screen, model: model, select: entry)
    }
    let importedMeetings = "legacyMeetingsImported"
    if !UserDefaults.standard.bool(forKey: importedMeetings) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Iridium")
            let count = meetings.importLegacy(from: old)
            UserDefaults.standard.set(true, forKey: importedMeetings)
            if count > 0 { model.show(notice: "Imported \(count) meetings") }
        }
    }
    if Setup.shared.needsOnboarding {
        OnboardingPanel.show(on: screen)
    }

    let engine: Engine
    do {
        guard let command = AppResources.engineCommand(asr: model.settings.speechModel, wav: wav) else {
            FileHandle.standardError.write(Data("uv was not found: install it from https://docs.astral.sh/uv\n".utf8))
            exit(1)
        }
        engine = try Engine(command: command, environment: AppResources.engineEnvironment(),
                            directory: AppResources.directory) { event in
            dock.handle(event)
            if ["partial", "final", "work"].contains(event.kind) { model.engineStalled = false }
            switch event.kind {
            case "stalled": model.engineStalled = true
            case "state":
                if event.recording {
                    model.recording = true
                    PhrasePlayer.shared.stop()
                    model.finishing = false
                    idle.arm(after: nil)
                    typist.startSession()
                    if model.notingNow { notes.startParagraph() }
                } else {
                    model.stopped()
                    idle.arm(after: model.idleUnloadMinutes)
                }
            case "ready":
                model.ready = true
                model.engineStalled = false
                model.correctionKeywords = event.cues
            case "level": if model.recording { model.receive(level: event.value) }
            case "partial": if !dock.hidesCaptions { captions.show(event.text) }
            case "final":
                if let edit = event.edit {
                    if !control.window.isKeyWindow { typist.revise(to: edit.text) }
                    if model.notingNow { notes.replaceDictated(with: edit.text, keepingBlock: true) }
                    for (id, text) in edit.phrases {
                        guard let at = model.history.lastIndex(where: { $0.phrase == id }) else { continue }
                        model.history[at].raw = model.history[at].raw ?? model.history[at].text
                        model.history[at].text = text
                        history.update(model.history[at])
                    }
                }
                if !dock.hidesCaptions, !event.text.isEmpty { captions.show(event.text) }
                if event.failed != nil { model.show(notice: "Cleanup failed. Nothing typed.") }
                let waitingAt = event.take.flatMap { take in
                    model.history.lastIndex { ($0.take == take || $0.id.uuidString == take) && $0.spoken.isEmpty }
                }
                let waiting = waitingAt.map { model.history[$0] }
                var entry = HistoryEntry(time: waiting?.time ?? Date(), text: event.text,
                                         raw: event.raw == event.text ? nil : event.raw,
                                         destination: waiting?.destination ?? model.destination, timing: event.timing,
                                         audio: event.audio.isEmpty ? waiting?.audio : event.audio, phrase: event.id,
                                         session: event.session, corrections: event.correction.map { [$0] })
                entry.take = waiting?.take ?? event.take
                entry.takeFile = waiting?.takeFile
                if let cleanupFailed = event.failed {
                    entry.state = .failed
                    entry.failure = cleanupFailed.isEmpty ? "Cleanup failed" : cleanupFailed
                }
                if let waitingAt, let waiting {
                    entry.id = waiting.id
                    model.history[waitingAt] = entry
                    history.update(entry)
                } else {
                    history.append(entry)
                    model.history.append(entry)
                }
                usage.record(entry)
                if event.late, let take = event.take {
                    if model.typingNow, !control.window.isKeyWindow, intents.mayType(take, frontApp: model.frontApp) {
                        typist.sync(entry.spoken, final: true)
                    } else if !entry.spoken.isEmpty {
                        model.show(notice: "Dictation saved to History")
                    }
                }
                if model.notingNow || event.take.map({ intents.wantsNotes($0) }) == true { notes.append(entry) }
                if let ms = event.cleanupMs, ms > 0 { model.lastCleanupMs = ms }
            case "session":
                let polish = PolishRun(text: event.text, heard: event.heard ?? event.text, cleanup: event.cleanup)
                if let last = event.phrases.last, let at = model.history.lastIndex(where: { $0.phrase == last }) {
                    model.history[at].polish = polish
                    if let run = event.correction {
                        model.history[at].corrections = (model.history[at].corrections ?? []) + [run]
                    }
                    history.update(model.history[at])
                    usage.record(polish: polish, of: model.history[at])
                }
                if event.polished, polish.text != polish.heard, !event.late {
                    notes.replaceDictated(with: polish.text)
                    if !control.window.isKeyWindow { typist.revise(to: polish.text) }
                }
            case "rewritten":
                if event.id == "note" {
                    model.cleaningNote = false
                    notes.replaceAll(with: event.text)
                } else if event.id?.hasPrefix("retry-") == true,
                          let id = event.id.flatMap({ UUID(uuidString: String($0.dropFirst(6))) }) {
                    model.retrying.remove(id)
                    if let failure = event.cleanup?.error {
                        model.show(notice: "Retry failed: \(failure)")
                    } else if let at = model.history.firstIndex(where: { $0.id == id }) {
                        model.history[at].raw = model.history[at].raw ?? model.history[at].text
                        model.history[at].text = event.text
                        if let run = event.correction {
                            model.history[at].corrections = (model.history[at].corrections ?? []) + [run]
                        }
                        history.update(model.history[at])
                    }
                }
                if let cleanup = event.cleanup { usage.record(rewrite: cleanup, at: Date()) }
            case "benchmark":
                guard let phrase = event.phrase,
                      let at = model.history.lastIndex(where: { $0.phrase == phrase }) else { break }
                model.history[at].benchmarks = event.results
                history.update(model.history[at])
                usage.record(benchmarks: event.results, of: model.history[at])
            case "type":
                if typist.isEnabled != model.typingNow { typist.isEnabled = model.typingNow }
                if !control.window.isKeyWindow { typist.sync(event.text, final: event.final) }
            case "take":
                guard let take = event.take else { break }
                let at = model.history.lastIndex { $0.take == take }
                switch event.takeState {
                case "recording":
                    intents.began(take, notes: model.notingNow, app: model.frontApp)
                    var entry = HistoryEntry(time: event.at.map(Date.init(timeIntervalSince1970:)) ?? Date(), text: "")
                    entry.destination = model.destination
                    entry.take = take
                    entry.takeFile = event.file
                    entry.state = .pending
                    history.append(entry)
                    model.history.append(entry)
                case "captured":
                    intents.stopped(take)
                    if let file = event.file {
                        model.lastRecording = (URL(fileURLWithPath: file).lastPathComponent, event.seconds ?? 0)
                    }
                    guard let at, model.history[at].isPending, let file = event.file,
                          let seconds = event.seconds, seconds > 0 else { break }
                    model.history[at].takeFile = file
                    model.history[at].audio = [AudioRef(file: file, start: 0, end: seconds)]
                    history.update(model.history[at])
                case "failed":
                    intents.forget(take)
                    guard let at, model.history[at].spoken.isEmpty else { break }
                    model.history[at].state = .failed
                    model.history[at].failure = event.status.message
                    model.history[at].takeFile = event.file ?? model.history[at].takeFile
                    history.update(model.history[at])
                    model.show(notice: event.status.message)
                case "empty", "discarded":
                    intents.forget(take)
                    guard let at, model.history[at].spoken.isEmpty else { break }
                    history.delete(model.history[at].id)
                    model.history.remove(at: at)
                default:
                    intents.forget(take)
                    guard !event.kept else { break }
                    for index in model.history.indices where model.history[index].take == take {
                        model.history[index].audio = nil
                        model.history[index].takeFile = nil
                        history.update(model.history[index])
                    }
                }
            case "retake":
                guard let take = event.take, let id = UUID(uuidString: take) else { break }
                model.retrying.remove(id)
                if let failure = event.failed {
                    model.show(notice: "Retry failed: \(failure)")
                } else if !event.said {
                    model.show(notice: "Nothing heard in that recording")
                }
            case "cleanup": model.cleanup = event.status
            case "work":
                model.finishing = event.pending && !model.recording
                if !event.pending { idle.arm(after: model.idleUnloadMinutes) }
            case "asr": model.speech = event.status
            case "notice": model.show(notice: event.text)
            default: break
            }
        }
    } catch {
        FileHandle.standardError.write(Data("could not start the engine: \(error)\n".utf8))
        exit(1)
    }

    let takes = { (settings: Settings) in
        engine.send("takes \(settings.saveAudio ? "keep" : "drop") \(recordings.path)")
    }
    let configure = {
        takes(model.settings)
        engine.send("hold \(model.settings.typingHold)")
        if model.settings.cleanupEnabled { engine.send(model.settings.cleanupCommand) }
        if !model.settings.cleanupInstructions.isEmpty { engine.send("instructions " + jsonString(model.settings.cleanupInstructions)) }
        engine.send(model.settings.cleanupPolish ? "polish on" : "polish off")
        if model.settings.cleanupBenchmark { engine.send("benchmark on") }
        engine.send(model.settings.correctionsCommand)
        engine.send(model.settings.rulesCommand)
        engine.send("compare " + model.settings.openRouterModels.map(\.id).joined(separator: ","))
        engine.send(model.settings.failureCommand)
    }
    configure()
    engine.onRestart = {
        model.ready = false
        model.engineStalled = false
        model.speech = ModelStatus(state: "loading")
        engine.send("asr \(model.settings.speechModel)")
        configure()
    }
    model.onRecord = { recording in
        if recording, model.notingNow { engine.send("context " + jsonString(notes.dictationContext)) }
        engine.send(recording ? "start" : "stop")
    }
    model.onUnload = { engine.send("unload") }
    idle.unload = {
        if !model.recording, !model.finishing, model.speech.state != "unloaded" { engine.send("unload") }
    }
    idle.arm(after: model.idleUnloadMinutes)
    model.onEditInstructions = {
        InstructionsPanel.show(text: model.settings.cleanupInstructions, on: control.window.screen ?? screen) {
            model.settings.cleanupInstructions = $0
        }
    }
    model.onCancel = { engine.send("cancel") }
    model.onDeleteHistory = { history.delete($0) }
    model.onRetryHistory = { entry in
        if entry.spoken.isEmpty, let file = entry.takeFile ?? entry.audio?.first?.file {
            model.retrying.insert(entry.id)
            engine.send("retake \(entry.id.uuidString) " + jsonString(file))
            return
        }
        let heard = entry.raw ?? entry.text
        guard !heard.isEmpty, model.settings.cleanupEnabled else { return model.show(notice: "Turn on AI cleanup to retry") }
        model.retrying.insert(entry.id)
        engine.send("rewrite retry-\(entry.id.uuidString) " + jsonString(heard))
    }
    model.onAddToNote = { entry in
        let text = entry.text.isEmpty ? entry.raw ?? "" : entry.text
        guard !text.isEmpty else { return }
        notes.startParagraph()
        notes.append(HistoryEntry(time: entry.time, text: text, phrase: entry.phrase, session: entry.session))
        model.show(notice: "Added to note")
    }
    model.onCleanUpNote = { text in engine.send("rewrite note " + jsonString(text)) }
    model.onShowBenchmarks = { BenchmarkPanel.show(history: model.history, on: control.window.screen ?? screen) }
    model.onManageModels = { ModelsPanel.show(on: control.window.screen ?? screen, model: model) }
    let ourselves = ProcessInfo.processInfo.processIdentifier
    let front = { @MainActor @Sendable (app: NSRunningApplication?) in
        if let app, app.processIdentifier != ourselves { model.frontApp = app.localizedName }
    }
    front(NSWorkspace.shared.frontmostApplication)
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                      queue: .main) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        MainActor.assumeIsolated { front(app) }
    }
    model.onOpenRecordings = {
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordings)
    }
    model.onTypingRequest = { wanted in
        model.typing = wanted && KeyboardSink.requestAccess()
        typist.isEnabled = model.typingNow
    }
    model.onPaneChange = { pane in
        notes.isActive = pane == .notes
        if pane == .notes { notes.followEnd(animated: false) }
    }

    hotkeys.hotkeys = model.settings.hotkeys
    hotkeys.isRecording = { model.recording }
    hotkeys.onStart = { action in
        if action == .meeting { return model.toggleMeetingRecording() }
        model.startRecording(for: action)
        typist.isEnabled = model.typingNow
    }
    hotkeys.onStop = { model.stopRecording() }
    hotkeys.onMeeting = { model.toggleMeetingRecording() }
    hotkeys.onCancel = {
        model.cancelRecording()
        typist.isEnabled = model.typingNow
    }
    if !model.settings.hotkeys.isEmpty { hotkeys.listenWhenAllowed { model.hotkeysListening = true } }
    model.onCaptureHotkey = { id in
        model.hotkeysListening = hotkeys.listen()
        guard model.hotkeysListening else { return }
        model.capturingHotkey = id
        hotkeys.onCapture = { pressed in
            model.capturingHotkey = nil
            guard let pressed, let index = model.settings.hotkeys.firstIndex(where: { $0.id == id }) else { return }
            model.settings.hotkeys[index].keyCode = pressed.keyCode
            model.settings.hotkeys[index].modifiers = pressed.modifiers
            model.settings.hotkeys[index].keyName = pressed.keyName
        }
    }
    model.onSettingsChange = { new, old in
        if new.typingHold != old.typingHold { engine.send("hold \(new.typingHold)") }
        if new.pasteApps != old.pasteApps { keys.pasteApps = Set(new.pasteApps) }
        if new.openRouterModels != old.openRouterModels {
            engine.send("compare " + new.openRouterModels.map(\.id).joined(separator: ","))
        }
        if new.cleanupCommand != old.cleanupCommand {
            engine.send(new.cleanupCommand)
            model.lastCleanupMs = nil
        }
        if new.speechModel != old.speechModel { engine.send("asr \(new.speechModel)") }
        if new.cleanupInstructions != old.cleanupInstructions { engine.send("instructions " + jsonString(new.cleanupInstructions)) }
        if new.cleanupPolish != old.cleanupPolish { engine.send(new.cleanupPolish ? "polish on" : "polish off") }
        if new.cleanupBenchmark != old.cleanupBenchmark { engine.send(new.cleanupBenchmark ? "benchmark on" : "benchmark off") }
        if new.correctionsCommand != old.correctionsCommand { engine.send(new.correctionsCommand) }
        if new.rulesCommand != old.rulesCommand { engine.send(new.rulesCommand) }
        if new.failureCommand != old.failureCommand { engine.send(new.failureCommand) }
        if new.autoUnload != old.autoUnload || new.autoUnloadMinutes != old.autoUnloadMinutes {
            idle.arm(after: model.idleUnloadMinutes)
        }
        if new.saveAudio != old.saveAudio { takes(new) }
        if new.hotkeys != old.hotkeys { hotkeys.hotkeys = new.hotkeys }
        captions.apply(new)
        if new.controlHidden != old.controlHidden { control.setHidden(new.controlHidden) }
    }
    model.scheduleReveal()
    let memory = MemoryMonitor { engine.pid }
    memory.onReading = { model.memory = $0 }

    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
            library.flush()
            history.flush()
            usage.flush()
        }
    }
    let exits = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                library.flush()
                history.flush()
                usage.flush()
                exit(0)
            }
        }
        source.activate()
        return source
    }
    withExtendedLifetime((memory, exits, statusItem)) { app.run() }
}

