import Foundation

/// One model call Iridium Live paid for, in the shape the token ledger already stores: the fields
/// `~/dev/resume-site/scripts/collect-tokens.mjs` posts for Claude Code, Codex and omp (`id`, `source`, `conv`, `day`,
/// `model`, `input`, `output`, `cacheRead`, `cacheWrite`, `total`), plus what only this app knows: the moment, the
/// provider, what the call cost, how long it took, and the history entry it belongs to.
struct UsageRecord: Codable, Equatable, Sendable {
    let id: String        // "iridium-live:<entry id>": re-sending it replaces the ledger row
    let source: String
    let app: String
    let conv: String
    let day: String       // YYYY-MM-DD, UTC, as the other sources slice it off their timestamps
    let ts: String        // ISO 8601
    let provider: String
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int
    let costUsd: Double
    let ms: Double
    let entry: String     // the history entry this phrase is in

    /// The record for one model call, or nothing when there was no call to pay for (skipped, failed, or the provider
    /// reported no tokens). `step` separates the calls one phrase can make — its own cleanup, the pass over the
    /// recording it ended, and each model a benchmark compared it against — so none of them overwrites another in
    /// the ledger.
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
        self.day = String(ts.prefix(10))  // the day the collector reads off the other sources' timestamps, in UTC
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

    /// The record for a finished phrase's own cleanup.
    init?(_ entry: HistoryEntry) {
        guard let cleanup = entry.timing?.cleanup else { return nil }
        self.init(cleanup, of: entry)
    }
}

/// Every cleanup call this app made: one JSON object per line in `usage.jsonl`, appended in order and flushed to the
/// disk off the main thread, for the token collector to pick up. Starting up backfills the phrases said before this
/// log existed from `history.jsonl`, skipping the ids already in the file, so a second launch adds nothing.
@MainActor
final class UsageLog {
    private let file: URL
    private let history: URL
    private let disk = DispatchQueue(label: "usage.disk")  // serial: the backfill runs before the first phrase lands

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("usage.jsonl")
        history = directory.appendingPathComponent("history.jsonl")
        backfill(before: Date())
    }

    /// Log a finished phrase, if cleanup called a model for it.
    func record(_ entry: HistoryEntry) {
        guard let record = UsageRecord(entry) else { return }
        append([record])
    }

    /// Log the pass over the whole recording this phrase ended.
    func record(polish: PolishRun, of entry: HistoryEntry) {
        guard let cleanup = polish.cleanup, let record = UsageRecord(cleanup, of: entry, step: "polish") else { return }
        append([record])
    }

    /// Log what the benchmark spent comparing the other models on this phrase.
    func record(benchmarks: [BenchmarkRun], of entry: HistoryEntry) {
        append(benchmarks.compactMap { UsageRecord($0.cleanup, of: entry, step: "bench:\($0.model)") })
    }

    /// Log one whole-text rewrite, which belongs to no phrase: "Clean up note" asked for it.
    func record(rewrite cleanup: PhraseTiming.Cleanup, at time: Date) {
        let stand = HistoryEntry(time: time, text: "")
        guard let record = UsageRecord(cleanup, of: stand, step: "rewrite") else { return }
        append([record])
    }

    /// Wait until every logged call is on disk.
    func flush() {
        disk.sync {}
    }

    /// Add the calls `history.jsonl` remembers and this log does not. Phrases from `start` on arrive live instead, so
    /// the two paths cannot write the same id.
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

    /// The ids already logged, so a backfill never writes a row twice.
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
