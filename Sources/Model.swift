import Foundation
import Observation

/// What the engine reports about a model it manages (speech or cleanup).
struct ModelStatus: Equatable {
    var state = "off"  // off, downloading, loading, ready, error
    var model: String?
    var progress = 0.0
    var message = ""
}

/// Where the notes text is scrolled, for the scroll indicator.
struct ScrollMetrics: Equatable {
    var visibleFraction: CGFloat = 1  // of the whole text
    var position: CGFloat = 0         // 0 at the top, 1 at the end
    var overflows: Bool { visibleFraction < 0.999 }
}

/// Everything the control shows, and every action it can take. The engine, typing and windows are wired in main.
@MainActor @Observable
final class AppModel {
    enum Pane: Int { case notes, history, settings }  // left to right, like their buttons

    static let barSize = CGSize(width: 336, height: 56)
    static let paneWidth: CGFloat = 400
    static let historyHeight: CGFloat = 360
    static let settingsHeight: CGFloat = 400
    static let libraryHeight: CGFloat = 340  // the notes pane while it lists the saved notes
    static let notesFooter: CGFloat = 20     // under the note's text: its name and the way into My notes
    static let lineHeight: CGFloat = 14     // the status line just above the bar: it hangs into the bar's empty top
    static let lineSpacing: CGFloat = 17    // each line above that one
    static let seam: CGFloat = 1
    /// The largest the glass ever gets: settings open with both status lines showing.
    static let maxGlassSize = CGSize(width: paneWidth, height: barSize.height + seam + settingsHeight + lineHeight + lineSpacing)

    var recording = false
    var recordingSince = Date()
    var ready = false
    private(set) var level = 0.0
    var speech = ModelStatus(state: "loading")
    var cleanup = ModelStatus()
    var lastCleanupMs: Double?
    var memory: MemoryReading?
    var lastRecording: (file: String, seconds: Double)?
    var finishing = false  // recording has stopped, the engine is still working through what it heard
    var frontApp: String?  // the app in front, where typed words land
    var hotkeysListening = false
    var capturingHotkey: UUID?  // the hotkey row waiting for a key press
    /// What the recording in progress is for, when a hotkey started it; nil when started from the record button.
    private(set) var session: Hotkey.Action?

    private(set) var pane: Pane?
    private(set) var notesCapturing = false
    var typing = false
    var notesHeight: CGFloat = 50
    var notesEditing = false
    var notesEmpty = true
    var notesScroll = ScrollMetrics()
    /// What the notes pane shows: the note being edited, or the list of saved notes.
    enum NotesView { case editor, library }
    var notesView = NotesView.editor
    var history: [HistoryEntry] = []
    /// The glass opens below the bar instead of above it: set when the control sits too high on the screen for the
    /// tallest pane to fit above.
    var opensDown = false

    /// Words are typed into the focused app: the typing switch is on, or a "type it" hotkey is recording.
    var typingNow: Bool { typing || session == .insert }
    /// Finished phrases go to the notes: notes are being kept, or an "add to notes" hotkey is recording.
    var notingNow: Bool { notesCapturing || session == .note }

    /// Where finished phrases are going, in a few words: "Notes", the app in front, or both.
    var destination: String? {
        let app = typingNow ? frontApp ?? "the app in front" : nil
        switch (app, notingNow) {
        case let (app?, true): return "\(app) and notes"
        case let (app?, false): return app
        case (nil, true): return "Notes"
        case (nil, false): return nil
        }
    }

    /// What the control is doing, for the line above the bar: where the words are going while recording, and that it
    /// is still finishing after a stop. Nothing worth saying otherwise.
    var activity: String? {
        if recording {
            switch (typingNow, notingNow) {
            case (true, true): return "Typing into \(frontApp ?? "the app in front") and notes"
            case (true, false): return "Typing into \(frontApp ?? "the app in front")"
            case (false, true): return "Writing to notes"
            case (false, false): return nil
            }
        }
        return finishing ? "Finishing" : nil
    }

    var settings = Settings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            onSettingsChange(settings, oldValue)
        }
    }

    var onRecord: (Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onTypingRequest: (Bool) -> Void = { _ in }  // main checks permission, then sets `typing`
    var onPaneChange: (Pane?) -> Void = { _ in }
    var onSettingsChange: (Settings, Settings) -> Void = { _, _ in }
    var onUnload: () -> Void = {}
    var onEditInstructions: () -> Void = {}

    /// How long to wait before unloading the models, counting from now: nil while recording or when switched off.
    var idleUnloadMinutes: Int? { settings.autoUnload && !recording ? settings.autoUnloadMinutes : nil }
    var onOpenRecordings: () -> Void = {}
    var onDeleteHistory: (UUID) -> Void = { _ in }
    var onCaptureHotkey: (UUID) -> Void = { _ in }

    /// Memory is tight. Settings says so beside a model that is loaded; the control itself stays quiet.
    var memoryWarning: Bool { memory?.warning == true }

    var paneHeight: CGFloat {
        switch pane {
        case .notes: (notesView == .library ? Self.libraryHeight : notesHeight + Self.notesFooter) + Self.seam
        case .history: Self.historyHeight + Self.seam
        case .settings: Self.settingsHeight + Self.seam
        case nil: 0
        }
    }

    /// The status line beside the bar: what it is doing.
    var linesHeight: CGFloat {
        activity == nil ? 0 : Self.lineHeight
    }

    /// The glass: the bar alone, or opened upward into a pane, with any status lines just above the bar.
    var glassSize: CGSize {
        CGSize(width: pane == nil ? Self.barSize.width : Self.paneWidth, height: Self.barSize.height + paneHeight + linesHeight)
    }

    /// The record button: a recording of your own, typed or noted as the switches say.
    func toggleRecording() {
        recording ? stopRecording() : startRecording(for: nil)
    }

    /// Start recording, for `action` when a hotkey asked. The purpose outlives the stop, so the phrase that finishes
    /// just after it still goes where it was meant to.
    func startRecording(for action: Hotkey.Action?) {
        session = action
        recording = true  // answer at once; the engine's state events confirm or undo it
        recordingSince = Date()
        onRecord(true)
    }

    func stopRecording() {
        recording = false
        onRecord(false)
    }

    /// Drop the recording in progress and whatever it heard: a hotkey tap that turned out not to be a hold.
    func cancelRecording() {
        recording = false
        session = nil
        onCancel()
    }

    /// The notes button: opens the notes and starts keeping them, or closes them and stops.
    func toggleNotes() {
        notesCapturing = pane != .notes
        go(to: notesCapturing ? .notes : nil)
    }

    /// The settings button: opens settings over whatever is showing; closing returns to the notes while they are kept.
    func toggleSettings() {
        toggle(.settings)
    }

    /// The history button: the same, for everything said so far.
    func toggleHistory() {
        toggle(.history)
    }

    /// Opens the notes pane on the list of saved notes ("My notes"), leaving note keeping as it was.
    func showMyNotes() {
        notesView = .library
        if pane != .notes { go(to: .notes) }
    }

    /// Remove a phrase from the history, on screen and on disk.
    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        onDeleteHistory(id)
    }

    /// Input level, 0...1: rises at once, falls gently.
    func receive(level value: Double) {
        level = max(value, level * 0.72)
    }

    func stopped() {
        recording = false
        level = 0
    }

    private func toggle(_ which: Pane) {
        go(to: pane == which ? (notesCapturing ? .notes : nil) : which)
    }

    private func go(to next: Pane?) {
        pane = next
        onPaneChange(next)
    }
}
