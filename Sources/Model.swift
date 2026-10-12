import AppKit
@preconcurrency import MeetingKit
import Observation

struct ModelStatus: Equatable {
    var state = "off"
    var model: String?
    var progress = 0.0
    var message = ""
}

struct ScrollMetrics: Equatable {
    var visibleFraction: CGFloat = 1
    var position: CGFloat = 0
    var overflows: Bool { visibleFraction < 0.999 }
}

@MainActor @Observable
final class AppModel {
    enum Pane: Int { case notes, meeting, history, settings }

    static let barSize = CGSize(width: 370, height: 56)
    static let paneWidth: CGFloat = 400
    static let historyHeight: CGFloat = 360
    static let settingsHeight: CGFloat = 400
    static let meetingHeight: CGFloat = 440
    static let libraryHeight: CGFloat = 340
    static let notesHeader: CGFloat = 34
    static let lineHeight: CGFloat = 14
    static let lineSpacing: CGFloat = 17
    static let seam: CGFloat = 1
    static let maxGlassSize = CGSize(width: paneWidth,
                                     height: barSize.height + seam + max(settingsHeight, meetingHeight)
                                         + lineHeight + lineSpacing)

    var recording = false
    var recordingSince = Date()
    var ready = false
    var engineStalled = false
    var notice: String?
    var correctionKeywords: [String] = []
    var retrying: Set<UUID> = []
    private(set) var level = 0.0
    var speech = ModelStatus(state: "loading")
    var cleanup = ModelStatus()
    var lastCleanupMs: Double?
    var memory: MemoryReading?
    var lastRecording: (file: String, seconds: Double)?
    var finishing = false
    var frontApp: String?
    var chatTarget: ChatTarget?
    var hotkeysListening = false
    var capturingHotkey: UUID?
    private(set) var session: Hotkey.Action?

    private(set) var pane: Pane?
    private(set) var notesCapturing = false
    var typing = false
    var notesHeight: CGFloat = 50
    var notesEditing = false
    var notesEmpty = true
    var notesScroll = ScrollMetrics()
    enum NotesView { case editor, library }
    var notesView = NotesView.editor
    var history: [HistoryEntry] = []
    var opensDown = false
    var modelsWindowActive = false

    var typingNow: Bool {
        if let chatTarget { return !chatTarget.collects }
        return typing || session == .insert
    }
    var notingNow: Bool { chatTarget == nil && (notesCapturing || session == .note) }

    var destination: String? {
        if let chatTarget { return chatTarget.name }
        let app = typingNow ? frontApp ?? "the app in front" : nil
        switch (app, notingNow) {
        case let (app?, true): return "\(app) and notes"
        case let (app?, false): return app
        case (nil, true): return "Notes"
        case (nil, false): return nil
        }
    }

    var activity: String? {
        if engineStalled { return "Engine not responding. Restart Iridium Live." }
        if let notice { return notice }
        switch speech.state {
        case "downloading": return "Downloading speech model \(Int(speech.progress * 100))%"
        case "loading": return "Loading speech model"
        case "error" where !ready: return "Speech model failed to load"
        default: if !ready { return "Loading speech model" }
        }
        if let chatTarget { return recording ? "Dictating to \(chatTarget.name)" : "Finishing" }
        if recording {
            switch (typingNow, notingNow) {
            case (true, true): return frontApp.map { "Typing into \($0) and notes" } ?? "Typing and writing to notes"
            case (true, false): return frontApp.map { "Typing into \($0)" } ?? "Typing"
            case (false, true): return "Writing to notes"
            case (false, false): return nil
            }
        }
        return finishing ? "Finishing" : nil
    }

    func show(notice text: String) {
        notice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.notice == text { self?.notice = nil }
        }
    }

    var settings = Settings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            Look.shared.apply(settings)
            onSettingsChange(settings, oldValue)
        }
    }

    var onRecord: (Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onTypingRequest: (Bool) -> Void = { _ in }
    var onPaneChange: (Pane?) -> Void = { _ in }
    var onSettingsChange: (Settings, Settings) -> Void = { _, _ in }
    var onUnload: () -> Void = {}
    var onEditInstructions: () -> Void = {}
    var onCleanUpNote: (String) -> Void = { _ in }
    var cleaningNote = false
    var onShowBenchmarks: () -> Void = {}
    var chatApps: ChatApps?
    var onEditChatApps: () -> Void = {}
    var meetings: MeetingsModel!
    var onOpenMeetings: (UUID?) -> Void = { _ in }

    var meetingRecording: Bool { meetings?.isRecording == true }

    func toggleMeeting() {
        toggle(.meeting)
    }

    func toggleMeetingRecording() {
        guard let meetings else { return }
        if !meetings.isRecording, pane != .meeting { go(to: .meeting) }
        meetings.toggleRecording()
    }

    func openMeetings(_ id: UUID? = nil) {
        onOpenMeetings(id)
    }

    func quit() {
        guard let meetings, meetings.isRecording else { return NSApp.terminate(nil) }
        Task {
            await meetings.stopRecording()
            NSApp.terminate(nil)
        }
    }

    var idleUnloadMinutes: Int? { settings.autoUnload && !recording ? settings.autoUnloadMinutes : nil }
    var onOpenRecordings: () -> Void = {}
    var onDeleteHistory: (UUID) -> Void = { _ in }
    var onRetryHistory: (HistoryEntry) -> Void = { _ in }
    var onAddToNote: (HistoryEntry) -> Void = { _ in }
    var onCaptureHotkey: (UUID) -> Void = { _ in }

    var paneHeight: CGFloat {
        switch pane {
        case .notes: (notesView == .library ? Self.libraryHeight : notesHeight + Self.notesHeader) + Self.seam
        case .meeting: Self.meetingHeight + Self.seam
        case .history: Self.historyHeight + Self.seam
        case .settings: Self.settingsHeight + Self.seam
        case nil: 0
        }
    }

    var linesHeight: CGFloat {
        activity == nil ? 0 : Self.lineHeight
    }

    var glassSize: CGSize {
        CGSize(width: pane == nil ? Self.barSize.width : Self.paneWidth, height: Self.barSize.height + paneHeight + linesHeight)
    }

    func toggleRecording() {
        if recording { stopRecording() } else { startRecording(for: nil) }
    }

    @discardableResult
    func startRecording(for action: Hotkey.Action?) -> Bool {
        guard ready else { return false }
        session = action
        recording = true
        recordingSince = Date()
        onRecord(true)
        return true
    }

    func stopRecording() {
        recording = false
        onRecord(false)
    }

    func cancelRecording() {
        recording = false
        session = nil
        onCancel()
    }

    func toggleNotes() {
        notesCapturing = pane != .notes
        go(to: notesCapturing ? .notes : nil)
    }

    func toggleSettings() {
        toggle(.settings)
    }

    func toggleHistory() {
        toggle(.history)
    }

    func use(_ saved: SavedModel) {
        if !settings.openRouterModels.contains(where: { $0.id == saved.id }) { settings.openRouterModels.append(saved) }
        settings.cleanupProvider = "openrouter"
        settings.cleanupModels["openrouter"] = saved.id
        settings.openRouterRecent = [saved.id] + settings.openRouterRecent.filter { $0 != saved.id }
    }

    func save(_ saved: SavedModel) {
        guard !settings.openRouterModels.contains(where: { $0.id == saved.id }) else { return }
        settings.openRouterModels.append(saved)
    }

    func removeSaved(_ id: String) {
        let known = settings.openRouterModels.map(\.id)
        let picked = settings.cleanupModels["openrouter"].flatMap { known.contains($0) ? $0 : nil } ?? settings.openRouterRecent.first
        let inUse = picked == id
        settings.openRouterModels.removeAll { $0.id == id }
        settings.openRouterRecent.removeAll { $0 == id }
        if inUse { settings.cleanupModels["openrouter"] = settings.savedModelsByRecency.first?.id ?? "" }
    }

    var onManageModels: () -> Void = {}

    func hideControl() {
        settings.controlHidden = true
    }

    func showControl() {
        settings.controlHidden = false
    }

    func showMyNotes() {
        notesView = .library
        if pane != .notes { go(to: .notes) }
    }

    func cleanUpNote(_ text: String) {
        guard settings.cleanupEnabled, !cleaningNote, !text.isEmpty else { return }
        cleaningNote = true
        onCleanUpNote(text)
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        onDeleteHistory(id)
    }

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

