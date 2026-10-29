import Foundation

/// A note as the filing model sees it.
struct NoteDigest: Sendable {
    let id: UUID
    let title: String
    let tags: [String]
    let gist: String
}

/// One stretch of dictated text with the note it belongs in.
struct FiledSegment: Sendable, Equatable {
    var text: String
    var title: String
    var tags: [String]
    /// The note it goes into, or nil for a new note.
    var target: UUID?
}

enum FilingError: Error, Equatable {
    case noKey
    case noAnswer(String)
    case unusable
}

/// Asks the cleanup model to split new note text by topic and say where each piece belongs.
struct NoteFiler: Sendable {
    let provider: String
    let model: String
    let key: String

    private static let maxTokens = 1500
    private static let textLimit = 12_000
    private static let gistLimit = 200

    static func endpoint(for provider: String) -> URL {
        provider == "groq" ? URL(string: "https://api.groq.com/openai/v1/chat/completions")!
                           : URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    }

    /// Splits `text` into segments aimed at `notes`, keeping every word of the original.
    func split(_ text: String, among notes: [NoteDigest], open: UUID?) async throws -> [FiledSegment] {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FilingError.noKey }
        let body = String(text.prefix(Self.textLimit))
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FilingError.unusable }
        let keys = notes.enumerated().map { ("n\($0.offset + 1)", $0.element) }
        let answer = try await ask(prompt(body, keys: keys, open: open))
        let raw = try Self.parse(answer)
        let byKey = Dictionary(uniqueKeysWithValues: keys.map { ($0.0, $0.1.id) })
        let aimed = raw.map { piece -> (String, FiledSegment) in
            let target = piece.note.flatMap { byKey[$0.lowercased()] }
            let quote = piece.start ?? piece.text ?? ""
            return (quote, FiledSegment(text: quote, title: piece.title ?? "", tags: piece.tags ?? [], target: target))
        }
        let segments = Self.align(aimed, to: body)
        guard !segments.isEmpty else { throw FilingError.unusable }
        return segments
    }

    private func prompt(_ text: String, keys: [(String, NoteDigest)], open: UUID?) -> [(String, String)] {
        let system = """
        You sort spoken notes. The speaker dictates into one pad and jumps between projects and topics.
        Split the new text into segments, one per topic, and say which note each segment belongs in.
        Rules:
        - Split only where the topic really changes. One topic is one segment. Most takes are one segment.
        - Give the first six words of each segment exactly as they appear in the text, never reworded.
        - Use an existing note id when a segment continues that note's subject, otherwise "new".
        - For a new note give a title of at most five words naming the subject.
        - Give every segment one to three short tags naming the project or subject, lowercase.
        Answer with JSON only, no prose:
        {"segments":[{"start":"first six words","note":"n1 or new","title":"...","tags":["..."]}]}
        """
        var lines: [String] = []
        for (id, note) in keys {
            let tags = note.tags.isEmpty ? "" : " tags: " + note.tags.joined(separator: ", ")
            let gist = note.gist.replacingOccurrences(of: "\n", with: " ").prefix(Self.gistLimit)
            let here = note.id == open ? " (the open note)" : ""
            lines.append("\(id): \"\(note.title)\"\(here)\(tags) — \(gist)")
        }
        let listing = lines.isEmpty ? "No notes yet." : lines.joined(separator: "\n")
        let user = """
        Existing notes:
        \(listing)

        New text:
        \(text)
        """
        return [("system", system), ("user", user)]
    }

    private func ask(_ messages: [(String, String)]) async throws -> String {
        var request = URLRequest(url: Self.endpoint(for: provider))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider != "groq" {
            request.setValue("https://github.com/SignedAdam/iridium-live", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Iridium Live", forHTTPHeaderField: "X-Title")
        }
        let parts = model.split(separator: "@", maxSplits: 1).map(String.init)
        var payload: [String: Any] = [
            "model": parts[0],
            "max_tokens": Self.maxTokens,
            "temperature": 0,
            "messages": messages.map { ["role": $0.0, "content": $0.1] },
        ]
        if parts.count == 2, provider != "groq" {
            payload["provider"] = ["order": [parts[1]], "allow_fallbacks": true]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FilingError.noAnswer("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw FilingError.noAnswer("\(http.statusCode) " + (String(data: data, encoding: .utf8)?.prefix(200) ?? ""))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw FilingError.noAnswer("no content") }
        return content
    }

    /// What the model returned, before it is checked against the real text.
    private struct Piece: Decodable {
        let start: String?
        let text: String?
        let note: String?
        let title: String?
        let tags: [String]?
    }

    private struct Answer: Decodable {
        let segments: [Piece]
    }

    private static func parse(_ answer: String) throws -> [Piece] {
        guard let json = object(in: answer), let data = json.data(using: .utf8) else {
            throw FilingError.noAnswer("not JSON")
        }
        if let decoded = try? JSONDecoder().decode(Answer.self, from: data) { return decoded.segments }
        if let pieces = try? JSONDecoder().decode([Piece].self, from: data) { return pieces }
        throw FilingError.noAnswer("unexpected shape")
    }

    private static func object(in answer: String) -> String? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let open = text.firstIndex(of: "{")
        let close = text.lastIndex(of: "}")
        if let open, let close, open < close { return String(text[open...close]) }
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return nil }
        return String(text[start...end])
    }

    /// Turns the model's segments into slices of the real text, so nothing is rewritten or lost.
    static func align(_ pieces: [(String, FiledSegment)], to text: String) -> [FiledSegment] {
        let original = Array(text)
        var plain: [Character] = []
        var map: [Int] = []
        for (position, character) in original.enumerated() where character.isLetter || character.isNumber {
            plain.append(Character(character.lowercased()))
            map.append(position)
        }
        guard !plain.isEmpty else { return [] }
        var cuts: [(Int, FiledSegment)] = []
        var cursor = 0
        for (quoted, segment) in pieces {
            let needle = Array(quoted.lowercased().filter { $0.isLetter || $0.isNumber }).prefix(48)
            guard needle.count >= 6 else { continue }
            guard let found = search(Array(needle), in: plain, from: cursor) else { continue }
            cuts.append((map[found], segment))
            cursor = min(found + needle.count, plain.count)
        }
        guard !cuts.isEmpty else { return [] }
        var filed: [FiledSegment] = []
        for (index, cut) in cuts.enumerated() {
            let start = index == 0 ? 0 : cut.0
            let end = index + 1 < cuts.count ? cuts[index + 1].0 : original.count
            guard start < end else { continue }
            var segment = cut.1
            segment.text = String(original[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.text.isEmpty else { continue }
            filed.append(segment)
        }
        return filed
    }

    private static func search(_ needle: [Character], in haystack: [Character], from: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var start = from
        while start + needle.count <= haystack.count {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return start }
            start += 1
        }
        return nil
    }
}

/// Runs filing after a note take and keeps one step of undo.
@MainActor @Observable
final class NoteFiling {
    /// What the pane shows after a run.
    struct Notice: Equatable {
        var text: String
        var undoable: Bool
    }

    private struct Snapshot {
        var pending: String
        var texts: [UUID: String]
        var tags: [UUID: [String]]
        var created: [UUID]
    }

    static let quiet = Duration.seconds(20)
    private static let shortest = 40

    private(set) var notice: Notice?
    private(set) var running = false

    @ObservationIgnored var pending: @MainActor () -> String = { "" }
    @ObservationIgnored var apply: @MainActor (String) -> Void = { _ in }

    /// How the model that files notes is built, replaced by the filing harness.
    @ObservationIgnored var filer: @MainActor () -> NoteFiler? = { nil }

    @ObservationIgnored private let library: NotesLibrary
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var undoable: Snapshot?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var fading: Task<Void, Never>?
    @ObservationIgnored private var dictated = false

    init(library: NotesLibrary, model: AppModel) {
        self.library = library
        self.model = model
        filer = { [weak model] in
            guard let model else { return nil }
            let provider = model.settings.cleanupProvider
            let pick = model.settings.cleanupModel
            guard !pick.isEmpty, let key = Keychain.shared.values()[provider], !key.isEmpty else { return nil }
            return NoteFiler(provider: provider, model: pick, key: key)
        }
    }

    var isOn: Bool { model.settings.notesFiling }

    /// True while a note take is waiting to be filed.
    var hasTake: Bool { dictated }

    /// A dictated phrase landed in the note: file it once the speaking stops.
    func noted() {
        dictated = true
        guard isOn else { return }
        waiting?.cancel()
        waiting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.quiet)
                guard !Task.isCancelled, let self else { return }
                if !model.recording { return run() }
            }
        }
    }

    /// The notes pane closed: file what is waiting right away.
    func closed() {
        guard dictated, !model.recording else { return }
        run()
    }

    func run() {
        waiting?.cancel()
        waiting = nil
        guard isOn, !running else { return }
        let text = pending()
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.shortest else { return }
        guard let maker = filer(), !maker.model.isEmpty else {
            dictated = false
            return
        }
        dictated = false
        let open = library.currentNote?.id
        let notes = library.digests()
        running = true
        Task { [weak self] in
            let segments = try? await maker.split(text, among: notes, open: open)
            guard let self else { return }
            running = false
            guard let segments, !segments.isEmpty else {
                dictated = true
                return
            }
            fileAway(segments, pending: text, open: open)
        }
    }

    func undo() {
        guard let snapshot = undoable else { return }
        undoable = nil
        for id in snapshot.created { library.delete(id) }
        for (id, text) in snapshot.texts { library.setText(text, for: id) }
        for (id, tags) in snapshot.tags { library.setTags(tags, for: id) }
        apply(snapshot.pending)
        show(Notice(text: "Filing undone", undoable: false), seconds: 4)
    }

    func dismiss() {
        fading?.cancel()
        notice = nil
    }

    private func fileAway(_ segments: [FiledSegment], pending text: String, open: UUID?) {
        var snapshot = Snapshot(pending: text, texts: [:], tags: [:], created: [])
        var kept: [FiledSegment] = []
        var created: [String: UUID] = [:]
        var landed: [String] = []
        for segment in segments {
            if let target = segment.target, target == open {
                kept.append(segment)
                continue
            }
            if let target = segment.target, let note = library.note(target) {
                if snapshot.texts[target] == nil {
                    snapshot.texts[target] = library.text(of: note)
                    snapshot.tags[target] = note.tags
                }
                library.append(segment.text, to: target)
                library.setTags(note.tags + segment.tags, for: target)
                landed.append(note.name)
                continue
            }
            let title = segment.title.isEmpty ? (segment.tags.first ?? "Note") : segment.title
            if let existing = created[title.lowercased()] {
                if let note = library.note(existing) {
                    library.append(segment.text, to: existing)
                    library.setTags(note.tags + segment.tags, for: existing)
                }
                continue
            }
            let note = library.create(named: title, text: segment.text, tags: segment.tags)
            created[title.lowercased()] = note.id
            snapshot.created.append(note.id)
            landed.append(note.name)
        }
        if let open, let note = library.note(open) {
            if snapshot.tags[open] == nil { snapshot.tags[open] = note.tags }
            library.setTags(note.tags + kept.flatMap(\.tags), for: open)
        }
        guard !landed.isEmpty else {
            undoable = nil
            return
        }
        apply(kept.map(\.text).joined(separator: "\n\n"))
        undoable = snapshot
        let place = landed.count == 1 ? landed[0] : "\(landed.count) notes"
        show(Notice(text: "Filed into \(place)", undoable: true), seconds: 90)
        model.show(notice: "Filed into \(place)")
    }

    private func show(_ next: Notice, seconds: Double) {
        fading?.cancel()
        notice = next
        fading = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, notice == next else { return }
            notice = nil
        }
    }
}
