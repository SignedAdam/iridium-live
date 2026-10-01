import Foundation

/// Keeps the notes on disk so nothing is ever lost:
/// - every change is written a moment after it happens, atomically and in order, off the main thread, and at once on
///   quit (`flush`);
/// - every dictated phrase goes to an append-only journal the moment it arrives, whatever later happens to the notes;
/// - the previous version is copied to `backups/` whenever a lot of text disappears at once, and at least hourly
///   while the notes keep changing (the newest 200 copies are kept).
@MainActor
final class NotesStore {
    private static let settle = 0.3            // seconds of quiet before a write
    nonisolated private static let keptBackups = 200
    private let file: URL
    private let journal: URL
    private let backups: URL
    private let disk = DispatchQueue(label: "notes.disk")  // serial: writes land in the order they were made
    private var pending: DispatchWorkItem?
    private var latest: String
    private var written: String
    private var lastBackup = Date.distantPast

    /// The notes as saved last time.
    let initialText: String

    init(directory: URL) {
        file = directory.appendingPathComponent("notes.txt")
        journal = directory.appendingPathComponent("journal.txt")
        backups = directory.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        initialText = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        latest = initialText
        written = initialText
    }

    /// A dictated phrase: into the journal right now, before anything else can happen to it.
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

    /// The notes now read `text`.
    func changed(_ text: String) {
        latest = text
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.write() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Write whatever is pending and wait until it is on disk.
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
