import Foundation

@MainActor
final class NotesStore {
    private static let settle = 0.3
    nonisolated private static let keptBackups = 200
    private let journal: URL
    private let backups: URL
    private let disk = DispatchQueue(label: "notes.disk")
    private var pending: DispatchWorkItem?
    private var written: String
    private var lastBackup = Date.distantPast

    private(set) var file: URL

    private(set) var latest: String

    let initialText: String

    init(directory: URL, file: URL) {
        self.file = file
        journal = directory.appendingPathComponent("journal.txt")
        backups = directory.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        initialText = Self.read(file)
        latest = initialText
        written = initialText
    }

    nonisolated static func read(_ file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    func recordPhrase(_ phrase: String) {
        let line = Date().ISO8601Format() + "\t" + phrase + "\n"
        let journal = self.journal
        disk.async { @Sendable in
            guard let handle = try? FileHandle(forWritingTo: journal) else {
                try? line.write(to: journal, atomically: true, encoding: .utf8)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    func changed(_ text: String) {
        latest = text
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.write() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    func switchTo(_ file: URL) -> String {
        flush()
        self.file = file
        let text = Self.read(file)
        latest = text
        written = text
        return text
    }

    func move(to destination: URL) {
        pending?.cancel()
        let text = latest
        let source = file
        file = destination
        written = text
        disk.async { @Sendable in
            try? text.write(to: destination, atomically: true, encoding: .utf8)
            try? "".write(to: source, atomically: true, encoding: .utf8)
        }
    }

    func relocate(to destination: URL) {
        file = destination
    }

    func flush() {
        pending?.cancel()
        write()
        disk.sync {}
    }

    private func write() {
        let text = latest
        guard text != written else { return }
        let previous = written
        written = text
        let backup = shouldBackUp(from: previous, to: text)
            ? backups.appendingPathComponent("notes-\(Self.stamp()).txt") : nil
        if backup != nil { lastBackup = Date() }
        let file = self.file
        let backups = self.backups
        disk.async { @Sendable in
            if let backup {
                try? previous.write(to: backup, atomically: true, encoding: .utf8)
                Self.prune(backups)
            }
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func shouldBackUp(from old: String, to new: String) -> Bool {
        guard !old.isEmpty else { return false }
        let lost = old.count - new.count
        let lostALot = lost > 400 || (old.count >= 120 && Double(new.count) < Double(old.count) * 0.7)
        return lostALot || Date().timeIntervalSince(lastBackup) > 3600
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return format.string(from: Date())
    }

    nonisolated private static func prune(_ backups: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasPrefix("notes-") }
        for name in names.sorted().dropLast(keptBackups) {
            try? FileManager.default.removeItem(at: backups.appendingPathComponent(name))
        }
    }
}

