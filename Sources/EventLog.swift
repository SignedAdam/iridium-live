import AppKit

/// Every decision about a recording, one line each, in ~/Library/Logs/Iridium Live/events.log: what the app asked
/// the engine, what ran (speech, cleanup, polish) and why text was or was not typed. The engine's lines come in as
/// `log` events, so the file has one writer and one order. Past 5 MB it moves to events.1.log.
@MainActor
final class EventLog {
    static let shared = EventLog()

    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Iridium Live/events.log")
    private static let limit = 5 << 20
    private var handle: FileHandle?
    private var size = 0
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        open()
        add("--- launched")
    }

    /// One line: when, who decided (`app` or `engine`), the recording it is about, what happened and why.
    func add(_ text: String, take: String? = nil, from source: String = "app") {
        let line = "\(stamp.string(from: Date()))  \(source.padding(toLength: 6, withPad: " ", startingAt: 0))  "
            + "\((take ?? "").padding(toLength: 12, withPad: " ", startingAt: 0))  \(text)\n"
        let data = Data(line.utf8)
        if size + data.count > Self.limit { open(fresh: true) }
        try? handle?.write(contentsOf: data)
        size += data.count
    }

    func show() {
        NSWorkspace.shared.open(url)
    }

    private func open(fresh: Bool = false) {
        let files = FileManager.default
        try? handle?.close()
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fresh || ((try? files.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > Self.limit {
            let older = url.deletingPathExtension().appendingPathExtension("1.log")
            try? files.removeItem(at: older)
            try? files.moveItem(at: url, to: older)
        }
        if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }
}
