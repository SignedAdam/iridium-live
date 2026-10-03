import AppKit

/// One line of engine output (the protocol is described in live.py).
struct EngineEvent: Sendable {
    let kind: String
    let text: String
    let final: Bool
    let recording: Bool
    let value: Double
    let status: ModelStatus  // "cleanup" and "asr" events
    let cleanupMs: Double?   // "final" events when cleanup ran
    let raw: String?         // "final" events when cleanup ran: the phrase as heard
    let file: String?        // "archive" events: a recording file just closed
    let seconds: Double?     // ... and how long it is
    let timing: PhraseTiming?  // "final" events: how long each step took
    let pending: Bool        // "work" events: still finishing what was recorded
    let audio: [AudioRef]    // "final" events while audio is saved: where the phrase is in the recordings
    let id: String?          // "final" events: the phrase's own id; "rewritten": the request it answers
    let session: Int?        // "final" and "session" events: the recording they belong to
    let heard: String?       // "session" events: its phrases as they were typed, run together
    let phrases: [String]    // ... and their ids
    let polished: Bool       // "session" events: the whole of it went through the model
    let cleanup: PhraseTiming.Cleanup?  // "session" and "rewritten" events: what that one pass cost
    let phrase: String?      // "benchmark" events: the phrase the other models answered
    let results: [BenchmarkRun]  // ... and what each of them wrote
    let edit: PhraseEdit?    // "final" events of a phrase that corrected earlier text
    let failed: String?      // "final" events whose cleanup failed and typed nothing: why
    let cues: [String]       // "ready": the words that start a spoken correction

    init?(line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let kind = object["kind"] as? String else { return nil }
        self.kind = kind
        text = object["text"] as? String ?? ""
        final = object["final"] as? Bool ?? false
        recording = object["recording"] as? Bool ?? false
        value = object["value"] as? Double ?? 0
        status = ModelStatus(state: object["state"] as? String ?? "off", model: object["model"] as? String,
                             progress: object["progress"] as? Double ?? 0, message: object["message"] as? String ?? "")
        cleanupMs = object["cleanup_ms"] as? Double
        raw = object["raw"] as? String
        file = object["file"] as? String
        seconds = object["seconds"] as? Double
        timing = PhraseTiming(engine: object["timing"])
        pending = object["pending"] as? Bool ?? false
        audio = (object["audio"] as? [[String: Any]] ?? []).compactMap(AudioRef.init(engine:))
        id = object["id"] as? String
        session = object["session"] as? Int
        heard = object["heard"] as? String
        phrases = object["phrases"] as? [String] ?? []
        polished = object["polished"] as? Bool ?? false
        // A phrase's "timing" holds its steps with the cleanup inside them; a session's and a rewrite's is the one
        // call they are.
        cleanup = kind == "final" ? nil : engineValue(object["timing"])
        phrase = object["phrase"] as? String
        results = (object["results"] as? [[String: Any]] ?? []).compactMap { engineValue($0) }
        edit = PhraseEdit(engine: object["edit"])
        failed = object["failed"] as? String
        cues = (object["cues"] as? [String] ?? []) + (object["starting_cues"] as? [String] ?? []).map { "\($0) (at the start)" }
    }
}

/// A spoken correction, as the engine made it: each earlier phrase it changed with its new text, and the recording's
/// whole text after it, which is what typed text, notes and a chat message are brought up to.
struct PhraseEdit: Sendable {
    let phrases: [(id: String, text: String)]
    let text: String

    init?(engine value: Any?) {
        guard let object = value as? [String: Any], let text = object["text"] as? String,
              let phrases = object["phrases"] as? [[String: Any]] else { return nil }
        self.text = text
        self.phrases = phrases.compactMap { phrase in
            (phrase["id"] as? String).flatMap { id in (phrase["text"] as? String).map { (id, $0) } }
        }
    }
}

/// `text` as a one-line JSON string literal, for commands whose argument may span lines.
func jsonString(_ text: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
}

/// The engine as a child process: commands go to its stdin, events come back from its stdout. Its stderr is ours in a
/// terminal (`make run`), and otherwise goes to `log`, which is where a hang or a crash leaves its trace.
/// When it exits, so does the app, unless it asked to be started again first ("restart": its microphone stuck in
/// CoreAudio, which only a new process gets back); then a fresh one takes its place and `onRestart` brings it up to
/// date. It is given its own environment rather than inheriting a shell's: launched from Finder there is none, and
/// the API keys come from the keychain.
@MainActor
final class Engine {
    /// The engine's log when the app was opened from Finder: this file and one older, 5 MB each at most.
    static let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Iridium Live/engine.log")

    /// After a restart: the new engine knows none of the settings the old one was sent.
    var onRestart: () -> Void = {}
    private let command: [String]
    private let environment: [String: String]
    private let directory: URL
    private let onEvent: @MainActor @Sendable (EngineEvent) -> Void
    private var process = Process()
    private var commands = Pipe()

    init(command: [String], environment: [String: String], directory: URL,
         onEvent: @escaping @MainActor @Sendable (EngineEvent) -> Void) throws {
        self.command = command
        self.environment = environment
        self.directory = directory
        self.onEvent = onEvent
        try launch()
    }

    private func launch() throws {
        let process = Process(), commands = Pipe(), events = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = commands
        process.standardOutput = events
        if isatty(STDERR_FILENO) == 0, let log = Self.openLog() { process.standardError = log }
        try process.run()
        self.process = process
        self.commands = commands
        let output = events.fileHandleForReading, onEvent = self.onEvent
        Task.detached { [weak self] in
            var restart = false
            do {
                for try await line in output.bytes.lines {
                    guard let event = EngineEvent(line: line) else { continue }
                    if event.kind == "restart" { restart = true }
                    await onEvent(event)
                }
            } catch {}  // a broken pipe means the engine is gone: same as a clean exit
            await MainActor.run {
                guard restart, let self, (try? self.launch()) != nil else { return NSApplication.shared.terminate(nil) }
                self.onRestart()
            }
        }
    }

    /// The engine's process (its own children, the Python interpreter among them, hang below it).
    var pid: pid_t { process.processIdentifier }

    /// Commands written before the engine is up wait in the pipe, so the app never has to.
    func send(_ command: String) {
        try? commands.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    /// The log, opened for appending with a line marking this launch; past 5 MB it becomes `engine.1.log` first.
    private static func openLog() -> FileHandle? {
        let files = FileManager.default
        try? files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 5 << 20 {
            let older = log.deletingPathExtension().appendingPathExtension("1.log")
            try? files.removeItem(at: older)
            try? files.moveItem(at: log, to: older)
        }
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("--- launched \(Date().ISO8601Format())\n".utf8))
        return handle
    }
}
