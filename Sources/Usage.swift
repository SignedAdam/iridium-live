import Foundation

struct UsageRecord: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let app: String
    let conv: String
    let day: String
    let ts: String
    let provider: String
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int
    let costUsd: Double
    let ms: Double
    let entry: String

    init?(_ cleanup: PhraseTiming.Cleanup, of entry: HistoryEntry, step: String = "") {
        guard !cleanup.skipped, cleanup.error == nil else { return nil }
        let input = Int(cleanup.promptTokens ?? 0), output = Int(cleanup.completionTokens ?? 0)
        guard input > 0 || output > 0 else { return nil }
        self.id = "iridium-live:\(entry.id.uuidString)\(step.isEmpty ? "" : ":" + step)"
        self.source = "iridium-live"
        self.app = "Iridium Live"
        self.conv = entry.id.uuidString
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let ts = formatter.string(from: entry.time)
        self.day = String(ts.prefix(10))
        self.ts = ts
        self.provider = cleanup.provider
        self.model = cleanup.model
        self.input = input
        self.output = output
        self.cacheRead = 0
        self.cacheWrite = 0
        self.total = input + output
        self.costUsd = cleanup.costUsd ?? 0
        self.ms = cleanup.ms
        self.entry = entry.id.uuidString
    }

    init?(_ entry: HistoryEntry) {
        guard let cleanup = entry.timing?.cleanup else { return nil }
        self.init(cleanup, of: entry)
    }
}

@MainActor
final class UsageLog {
    private let file: URL
    private let history: URL
    private let disk = DispatchQueue(label: "usage.disk")

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("usage.jsonl")
        history = directory.appendingPathComponent("history.jsonl")
        backfill(before: Date())
    }

    func record(_ entry: HistoryEntry) {
        guard let record = UsageRecord(entry) else { return }
        append([record])
    }

    func record(polish: PolishRun, of entry: HistoryEntry) {
        guard let cleanup = polish.cleanup, let record = UsageRecord(cleanup, of: entry, step: "polish") else { return }
        append([record])
    }

    func record(benchmarks: [BenchmarkRun], of entry: HistoryEntry) {
        append(benchmarks.compactMap { UsageRecord($0.cleanup, of: entry, step: "bench:\($0.model)") })
    }

    func record(rewrite cleanup: PhraseTiming.Cleanup, at time: Date) {
        let stand = HistoryEntry(time: time, text: "")
        guard let record = UsageRecord(cleanup, of: stand, step: "rewrite") else { return }
        append([record])
    }

    func flush() {
        disk.sync {}
    }

    private func backfill(before start: Date) {
        let file = self.file, history = self.history
        disk.async { @Sendable in
            guard let text = try? String(contentsOf: history, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let known = UsageLog.ids(in: file)
            let missing = text.split(separator: "\n")
                .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
                .filter { $0.time < start }
                .compactMap { UsageRecord($0) }
                .filter { !known.contains($0.id) }
            UsageLog.write(missing, to: file)
        }
    }

    private func append(_ records: [UsageRecord]) {
        let file = self.file
        disk.async { @Sendable in UsageLog.write(records, to: file) }
    }

    private nonisolated static func ids(in file: URL) -> Set<String> {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return Set(text.split(separator: "\n").compactMap { try? decoder.decode(UsageRecord.self, from: Data($0.utf8)).id })
    }

    private nonisolated static func write(_ records: [UsageRecord], to file: URL) {
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder()
        guard let lines = try? records.map({ try encoder.encode($0) + Data("\n".utf8) }).reduce(Data(), +) else { return }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? lines.write(to: file, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: lines)
        try? handle.synchronize()
    }
}

