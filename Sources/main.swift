// PhononLive: runs the speech engine (live.py) as a child process and puts it on screen: a floating glass control
// (record; notes; typing into the focused app; settings) and live captions. Nothing takes focus unless you click into
// the notes, so typing goes to the app you were in.
// Usage: PhononLive FONT.ttf ENGINE-COMMAND...
import AppKit

signal(SIGPIPE, SIG_IGN)  // a dead engine must not take the app down mid-write; its exit ends the app instead
MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("usage: PhononLive FONT.ttf ENGINE-COMMAND...\n".utf8))
        exit(2)
    }
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: arguments[0]) as CFURL, .process, nil)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
    let model = AppModel()
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PhononLive")
    let store = NotesStore(directory: support)
    let history = HistoryStore(directory: support)
    model.history = history.load()
    let notes = NotesEditor(model: model, store: store)
    let captions = Captions(screen: screen, settings: model.settings)
    let typist = Typist(sink: KeyboardSink())
    let control = ControlWindowController(model: model, notes: notes, screen: screen)
    let hotkeys = HotkeyMonitor()
    let idle = IdleUnloader()
    let recordings = support.appendingPathComponent("Recordings")

    let engine: Engine
    do {
        engine = try Engine(command: Array(arguments.dropFirst()) + ["--asr", model.settings.speechModel]) { event in
            switch event.kind {
            case "state":
                if event.recording {
                    model.recording = true
                    model.finishing = false
                    idle.arm(after: nil)
                    if model.notingNow { notes.startParagraph() }
                } else {
                    model.stopped()
                    idle.arm(after: model.idleUnloadMinutes)
                }
            case "ready": model.ready = true
            case "level": if model.recording { model.receive(level: event.value) }
            case "partial": captions.show(event.text)
            case "final":
                captions.show(event.text)
                let entry = HistoryEntry(time: Date(), text: event.text, raw: event.raw == event.text ? nil : event.raw,
                                         destination: model.destination, timing: event.timing,
                                         audio: event.audio.isEmpty ? nil : event.audio)
                history.append(entry)
                model.history.append(entry)
                if model.notingNow { notes.append(event.text) }
                if let ms = event.cleanupMs, ms > 0 { model.lastCleanupMs = ms }
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
    engine.send("hold \(model.settings.typingHold)")
    if model.settings.cleanupEnabled { engine.send(model.settings.cleanupCommand) }
    if !model.settings.cleanupInstructions.isEmpty { engine.send("instructions " + jsonString(model.settings.cleanupInstructions)) }
    if model.settings.saveAudio { archive(model.settings) }
    model.onRecord = { engine.send($0 ? "start" : "stop") }
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
    if !model.settings.hotkeys.isEmpty { model.hotkeysListening = hotkeys.listen() }
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
        if new.autoUnload != old.autoUnload || new.autoUnloadMinutes != old.autoUnloadMinutes {
            idle.arm(after: model.idleUnloadMinutes)
        }
        if new.saveAudio != old.saveAudio || new.audioSplitSeconds != old.audioSplitSeconds { archive(new) }
        if new.hotkeys != old.hotkeys { hotkeys.hotkeys = new.hotkeys }
        captions.apply(new)
        control.opacity = new.controlOpacity
    }
    let memory = MemoryMonitor(enginePID: engine.pid)
    memory.onReading = { model.memory = $0 }

    // Nothing may be lost on the way out: flush the notes and the history on a normal quit and on the signals that
    // end us from outside. (Set up after the engine starts, so the engine keeps the default signal handling.)
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
            store.flush()
            history.flush()
        }
    }
    let exits = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                store.flush()
                history.flush()
                exit(0)
            }
        }
        source.activate()
        return source
    }
    withExtendedLifetime((memory, exits)) { app.run() }
}
