import Foundation

/// Where a recording stands. Old history lines carry no state and are simply done.
enum TakeState: String, Codable, Sendable {
    case pending, failed
}

/// The engine's record of recordings in flight. What a crash leaves behind is found here at the next launch.
struct TakeJournal {
    struct Lost {
        let take: String
        let file: String?
        let at: Date
        let seconds: Double?

        var ref: AudioRef? {
            guard let file, let seconds, seconds > 0 else { return nil }
            return AudioRef(file: file, start: 0, end: seconds)
        }
    }

    let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("takes.jsonl")
    }

    /// Takes the engine opened but never finished, oldest first.
    func unfinished() -> [Lost] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var order: [String] = []
        var state: [String: String] = [:]
        var seen: [String: Lost] = [:]
        for line in text.split(separator: "\n") {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let take = item["take"] as? String, let status = item["state"] as? String else { continue }
            if state[take] == nil { order.append(take) }
            state[take] = status
            let path = item["file"] as? String ?? seen[take]?.file
            let at = (item["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? seen[take]?.at ?? Date()
            seen[take] = Lost(take: take, file: path, at: at,
                              seconds: item["seconds"] as? Double ?? seen[take]?.seconds ?? Self.length(path))
        }
        return order.filter { ["recording", "captured"].contains(state[$0] ?? "") }.compactMap { seen[$0] }
    }

    func clear() {
        try? Data().write(to: file, options: .atomic)
    }

    /// Seconds of 16 kHz mono audio in a file whose header a killed engine may never have finished.
    private static func length(_ path: String?) -> Double? {
        guard let path, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > 44 else { return nil }
        return Double(size - 44) / 2 / 16000
    }
}

/// What a recording was aimed at while it ran, so text that arrives late lands where it was meant to.
@MainActor
final class TakeIntents {
    private struct Intent {
        var notes: Bool
        var typing: Bool
        var app: String?
        var stopped: Date?
    }

    private var intents: [String: Intent] = [:]
    /// The newest recording: what the typist typed, and may still revise, is its own.
    private(set) var latest: String?

    func began(_ take: String, notes: Bool, typing: Bool, app: String?) {
        intents[take] = Intent(notes: notes, typing: typing, app: app)
        latest = take
    }

    func stopped(_ take: String) {
        intents[take]?.stopped = Date()
    }

    func forget(_ take: String) {
        intents[take] = nil
    }

    func wantsNotes(_ take: String) -> Bool {
        intents[take]?.notes ?? false
    }

    func wantsTyping(_ take: String) -> Bool {
        intents[take]?.typing ?? false
    }

    /// Why text that arrives after its recording stopped is not typed, or nil when it is: however late, it is typed
    /// while nothing has moved since, with the same app in front, no newer recording, and no key or click after the stop.
    func refusal(_ take: String, frontApp: String?, touched: Date?) -> String? {
        guard let intent = intents[take], intent.typing else { return "it was not for typing" }
        if take != latest { return "a newer recording started" }
        if intent.app != frontApp { return "\(frontApp ?? "another app") is in front, not \(intent.app ?? "the app it was for")" }
        if let stopped = intent.stopped, let touched, touched > stopped { return "you typed or clicked after it stopped" }
        return nil
    }
}

@MainActor
enum TakeRecovery {
    static let reason = "Iridium Live stopped before this was transcribed"

    /// Marks every recording a crash left behind as failed, so it shows up in History with a retry.
    @discardableResult
    static func run(journal: TakeJournal, history: inout [HistoryEntry], store: HistoryStore) -> Int {
        let lost = journal.unfinished()
        guard !lost.isEmpty else { return 0 }
        var found = 0
        for take in lost {
            if let at = history.lastIndex(where: { $0.take == take.take }) {
                guard history[at].text.isEmpty, history[at].state != .failed else { continue }
                history[at].state = .failed
                history[at].failure = reason
                history[at].takeFile = history[at].takeFile ?? take.file
                history[at].audio = history[at].audio ?? take.ref.map { [$0] }
                store.update(history[at])
            } else {
                var entry = HistoryEntry(time: take.at, text: "")
                entry.audio = take.ref.map { [$0] }
                entry.take = take.take
                entry.takeFile = take.file
                entry.state = .failed
                entry.failure = reason
                history.append(entry)
                store.append(entry)
            }
            found += 1
        }
        history.sort { $0.time < $1.time }
        journal.clear()
        return found
    }
}
