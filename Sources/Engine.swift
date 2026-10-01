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
    }
}

/// The engine as a child process: commands go to its stdin, events come back from its stdout, its stderr is ours.
/// When it exits, so does the app.
@MainActor
final class Engine {
    private let process = Process()
    private let commands = Pipe()

    init(command: [String], onEvent: @escaping @MainActor @Sendable (EngineEvent) -> Void) throws {
        let events = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = commands
        process.standardOutput = events
        try process.run()
        let output = events.fileHandleForReading
        Task.detached {
            do {
                for try await line in output.bytes.lines {
                    if let event = EngineEvent(line: line) { await onEvent(event) }
                }
            } catch {}  // a broken pipe means the engine is gone: same as a clean exit
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    /// The engine's process (its own children, the Python interpreter among them, hang below it).
    var pid: pid_t { process.processIdentifier }

    /// Commands written before the engine is up wait in the pipe, so the app never has to.
    func send(_ command: String) {
        try? commands.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }
}
