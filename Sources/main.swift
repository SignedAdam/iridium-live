// Iridium Live: runs the speech engine (live.py) as a child process and puts it on screen: a floating glass control
// (record; notes; typing into the focused app; settings) and live captions. Nothing takes focus unless you click into
// the notes, so typing goes to the app you were in.
// Everything it runs on — the engine scripts, the font, uv — is found from the bundle and the usual install paths,
// since a launch from Finder brings no shell with it. Usage: Iridium Live [--wav FILE] [--check]
import AppKit

signal(SIGPIPE, SIG_IGN)  // a dead engine must not take the app down mid-write; its exit ends the app instead
MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--check") {
        print(AppResources.report())
        exit(0)
    }
    let wav = arguments.firstIndex(of: "--wav").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    CTFontManagerRegisterFontsForURL(AppResources.font as CFURL, .process, nil)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu(in: app)
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
    let model = AppModel()
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Iridium Live")
    Migration.carryOver(to: support)
    let library = NotesLibrary(directory: support)
    let history = HistoryStore(directory: support)
    let usage = UsageLog(directory: support)
    model.history = history.load()
    let notes = NotesEditor(model: model, library: library)
    let captions = Captions(screen: screen, settings: model.settings)
    let typist = Typist(sink: KeyboardSink())
    let control = ControlWindowController(model: model, notes: notes, screen: screen)
    let hotkeys = HotkeyMonitor()
    let idle = IdleUnloader()
    let recordings = support.appendingPathComponent("Recordings")
    let dock = ChatDock(model: model, directory: support)
    let statusItem = StatusItem(model: model)
    model.chatApps = dock.apps
    model.onEditChatApps = { dock.editProfiles(on: control.window.screen ?? screen) }
    // Microphone, Accessibility, the cleanup keys and opening at login, in a window of their own. It never holds the
    // app up: whatever is missing only costs the part of the app that needs it.
    if Setup.shared.needsOnboarding {
        OnboardingPanel.show(on: screen, tint: model.settings.glassTint, opacity: model.settings.controlOpacity)
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
            if ["partial", "final", "work"].contains(event.kind) { model.engineStalled = false }  // it is moving again
            switch event.kind {
            case "stalled": model.engineStalled = true
            case "state":
                if event.recording {
                    model.recording = true
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
                    // The phrase corrected earlier text: everything that holds this recording is brought up to the
                    // corrected version first, under the same rules as the pass at the end, then the phrase lands.
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
                let entry = HistoryEntry(time: Date(), text: event.text, raw: event.raw == event.text ? nil : event.raw,
                                         destination: model.destination, timing: event.timing,
                                         audio: event.audio.isEmpty ? nil : event.audio, phrase: event.id,
                                         session: event.session)
                history.append(entry)
                usage.record(entry)
                model.history.append(entry)
                if model.notingNow { notes.append(entry) }
                if let ms = event.cleanupMs, ms > 0 { model.lastCleanupMs = ms }
            case "session":
                // The recording as one text: the notes take it in place of exactly what they appended, the typed
                // text is corrected where that is still ours to do, and the phrase it ended keeps what it cost.
                let polish = PolishRun(text: event.text, heard: event.heard ?? event.text, cleanup: event.cleanup)
                if let last = event.phrases.last, let at = model.history.lastIndex(where: { $0.phrase == last }) {
                    model.history[at].polish = polish
                    history.update(model.history[at])
                    usage.record(polish: polish, of: model.history[at])
                }
                if event.polished, polish.text != polish.heard {
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
                // While our window has the keyboard (editing the notes, using a control), keys would land in it.
                if !control.window.isKeyWindow { typist.sync(event.text, final: event.final) }
            case "archive":
                if let file = event.file { model.lastRecording = (URL(fileURLWithPath: file).lastPathComponent, event.seconds ?? 0) }
            case "cleanup": model.cleanup = event.status
            case "work":
                model.finishing = event.pending && !model.recording
                if !event.pending { idle.arm(after: model.idleUnloadMinutes) }
            case "asr": model.speech = event.status
            default: break
            }
        }
    } catch {
        FileHandle.standardError.write(Data("could not start the engine: \(error)\n".utf8))
        exit(1)
    }

    let archive = { (settings: Settings) in
        engine.send(settings.saveAudio ? "archive on \(settings.audioSplitSeconds) \(recordings.path)" : "archive off")
    }
    /// What the engine is told at launch, and again after a restart: a new engine knows none of it.
    let configure = {
        engine.send("hold \(model.settings.typingHold)")
        if model.settings.cleanupEnabled { engine.send(model.settings.cleanupCommand) }
        if !model.settings.cleanupInstructions.isEmpty { engine.send("instructions " + jsonString(model.settings.cleanupInstructions)) }
        engine.send(model.settings.cleanupPolish ? "polish on" : "polish off")
        if model.settings.cleanupBenchmark { engine.send("benchmark on") }
        engine.send(model.settings.correctionsCommand)
        engine.send(model.settings.rulesCommand)
        engine.send(model.settings.failureCommand(folder: recordings.path))
        if model.settings.saveAudio { archive(model.settings) }
    }
    configure()
    engine.onRestart = {
        model.ready = false  // nothing records until the new engine has its model in
        model.engineStalled = false
        model.speech = ModelStatus(state: "loading")
        engine.send("asr \(model.settings.speechModel)")  // the launch command names the model the app started with
        configure()
    }
    // What the dictation is about to continue goes with it: the cleanup model reads the end of the note in front of
    // every phrase, and the pass over the whole recording knows what it was written into.
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
        InstructionsPanel.show(text: model.settings.cleanupInstructions, on: control.window.screen ?? screen,
                               tint: model.settings.glassTint, opacity: model.settings.controlOpacity) {
            model.settings.cleanupInstructions = $0
        }
    }
    model.onCancel = { engine.send("cancel") }
    model.onDeleteHistory = { history.delete($0) }
    model.onRetryHistory = { entry in
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
    // The app typed words land in, for the line above the bar and the history (never ourselves: our panels do not
    // take the keyboard from it).
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
        model.startRecording(for: action)
        typist.isEnabled = model.typingNow
    }
    hotkeys.onStop = { model.stopRecording() }
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
        if new.failureCommand(folder: "") != old.failureCommand(folder: "") {
            engine.send(new.failureCommand(folder: recordings.path))
        }
        if new.autoUnload != old.autoUnload || new.autoUnloadMinutes != old.autoUnloadMinutes {
            idle.arm(after: model.idleUnloadMinutes)
        }
        if new.saveAudio != old.saveAudio || new.audioSplitSeconds != old.audioSplitSeconds { archive(new) }
        if new.hotkeys != old.hotkeys { hotkeys.hotkeys = new.hotkeys }
        captions.apply(new)
        control.opacity = new.controlOpacity
        if new.controlHidden != old.controlHidden { control.setHidden(new.controlHidden) }
    }
    let memory = MemoryMonitor { engine.pid }
    memory.onReading = { model.memory = $0 }

    // Nothing may be lost on the way out: flush the notes and the history on a normal quit and on the signals that
    // end us from outside. (Set up after the engine starts, so the engine keeps the default signal handling.)
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
