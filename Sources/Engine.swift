import AppKit

struct EngineEvent: Sendable {
    let kind: String
    let text: String
    let final: Bool
    let recording: Bool
    let value: Double
    let status: ModelStatus
    let cleanupMs: Double?
    let raw: String?
    let file: String?
    let seconds: Double?
    let timing: PhraseTiming?
    let pending: Bool
    let audio: [AudioRef]
    let id: String?
    let session: Int?
    let heard: String?
    let phrases: [String]
    let polished: Bool
    let cleanup: PhraseTiming.Cleanup?
    let phrase: String?
    let results: [BenchmarkRun]
    let edit: PhraseEdit?
    let failed: String?
    let cues: [String]

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
        cleanup = kind == "final" ? nil : engineValue(object["timing"])
        phrase = object["phrase"] as? String
        results = (object["results"] as? [[String: Any]] ?? []).compactMap { engineValue($0) }
        edit = PhraseEdit(engine: object["edit"])
        failed = object["failed"] as? String
        cues = (object["cues"] as? [String] ?? []) + (object["starting_cues"] as? [String] ?? []).map { "\($0) (at the start)" }
    }
}

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

func jsonString(_ text: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
}

@MainActor
final class Engine {
    static let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Iridium Live/engine.log")

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
            } catch {}
            await MainActor.run {
                guard restart, let self, (try? self.launch()) != nil else { return NSApplication.shared.terminate(nil) }
                self.onRestart()
            }
        }
    }

    var pid: pid_t { process.processIdentifier }

    func send(_ command: String) {
        try? commands.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

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

