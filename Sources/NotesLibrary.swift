import Foundation

/// A dictated phrase that went into a note: the history entry it came from, and where it can be heard again.
struct NoteLink: Codable, Equatable, Sendable {
    let entry: UUID
    var audio: [AudioRef]?
}

/// A saved note: a file in the notes folder, and everything known about it.
struct SavedNote: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var file: String            // the file name inside the notes folder, named after the note
    var name: String
    var created = Date()
    var modified = Date()
    var favorite = false
    var preview = ""            // the first line, for the list
    var links: [NoteLink] = []  // every dictated phrase that went into this note, in order
}

/// Every saved note: one file each in `Notes/`, named after the note, with `Notes/index.json` beside them holding
/// what the files cannot (when each was made, whether it is a favourite, and which dictated phrases went into it).
/// One note is current — the unsaved scratch (`notes.txt`) or a saved one — and `store` writes every keystroke of it
/// to disk with the same guarantees either way.
@MainActor @Observable
final class NotesLibrary {
    /// The index, as it is kept on disk.
    private struct Index: Codable {
        var notes: [SavedNote] = []
        var scratch: [NoteLink] = []  // the phrases in the unsaved scratch, carried over when it is saved
        var current: UUID?
    }

    /// What the scratch is called while it has no name of its own.
    static let scratchName = "Unsaved"
    private static let settle = 0.3

    /// Where the saved notes live, for Finder.
    let folder: URL
    let store: NotesStore
    private let indexFile: URL
    private let scratch: URL
    private let disk = DispatchQueue(label: "notes.library")
    private var index: Index
    private var saving: DispatchWorkItem?

    /// The text of the note that just became current, for the editor to show.
    @ObservationIgnored var onOpen: (String) -> Void = { _ in }

    /// The note whose name is being typed right now, just after it was saved.
    var naming: UUID?

    init(directory: URL) {
        let notes = directory.appendingPathComponent("Notes")
        folder = notes
        indexFile = notes.appendingPathComponent("index.json")
        scratch = directory.appendingPathComponent("notes.txt")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        var loaded = (try? Data(contentsOf: notes.appendingPathComponent("index.json")))
            .flatMap { try? Self.coder().decode(Index.self, from: $0) } ?? Index()
        // The files are the truth: notes whose file is gone are gone, and files the index never heard of are notes
        // all the same (an index lost or damaged costs names and links, never text).
        let names = Set(loaded.notes.map(\.file))
        loaded.notes.removeAll { !FileManager.default.fileExists(atPath: notes.appendingPathComponent($0.file).path) }
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !names.contains($0) }
        for file in found.sorted() {
            let text = NotesStore.read(notes.appendingPathComponent(file))
            loaded.notes.append(SavedNote(file: file, name: String(file.dropLast(3)), preview: Self.preview(text)))
        }
        if let current = loaded.current, !loaded.notes.contains(where: { $0.id == current }) { loaded.current = nil }
        index = loaded
        let file = loaded.current
            .flatMap { id in loaded.notes.first { $0.id == id } }
            .map { notes.appendingPathComponent($0.file) } ?? directory.appendingPathComponent("notes.txt")
        store = NotesStore(directory: directory, file: file)
        if !found.isEmpty { saveIndex() }
    }

    /// The text the editor opens on.
    var initialText: String { store.initialText }

    var notes: [SavedNote] { index.notes }

    /// Favourites first, then newest.
    var sorted: [SavedNote] {
        index.notes.sorted { $0.favorite == $1.favorite ? $0.modified > $1.modified : $0.favorite }
    }

    /// The note being edited, or nothing while that is the unsaved scratch.
    var currentNote: SavedNote? { index.current.flatMap { id in index.notes.first { $0.id == id } } }

    /// What to call the note being edited.
    var currentName: String { currentNote?.name ?? Self.scratchName }

    func note(_ id: UUID) -> SavedNote? { index.notes.first { $0.id == id } }

    func url(of note: SavedNote) -> URL { folder.appendingPathComponent(note.file) }

    /// A note's text: from the editor when it is the one open, otherwise from its file.
    func text(of note: SavedNote) -> String {
        note.id == index.current ? store.latest : NotesStore.read(url(of: note))
    }

    /// The notes now read `text`: to disk at once, and into the current note's summary.
    func changed(_ text: String) {
        store.changed(text)
        guard let position = position(of: index.current) else { return }
        index.notes[position].modified = Date()
        index.notes[position].preview = Self.preview(text)
        saveIndex()
    }

    /// A dictated phrase: into the journal now, and onto the current note's record of what went into it.
    func record(_ entry: HistoryEntry) {
        store.recordPhrase(entry.text)
        let link = NoteLink(entry: entry.id, audio: entry.audio)
        if let position = position(of: index.current) {
            index.notes[position].links.append(link)
        } else {
            index.scratch.append(link)
        }
        saveIndex()
    }

    /// Save the scratch as the next "Note N" and go on editing it under that name. A note already saved is returned
    /// unchanged.
    @discardableResult
    func save(_ text: String) -> SavedNote {
        if let note = currentNote { return note }
        let note = add(name: nextName(), text: text, links: index.scratch)
        index.scratch = []
        index.current = note.id
        store.move(to: url(of: note))  // the scratch's text becomes the note's; the scratch is left empty
        saveIndex()
        return note
    }

    /// Save a piece of the current note as a note of its own, leaving the one being edited as it is.
    @discardableResult
    func saveSelection(_ text: String) -> SavedNote {
        let note = add(name: nextName(), text: text, links: [])
        let file = url(of: note)
        disk.async { @Sendable in try? text.write(to: file, atomically: true, encoding: .utf8) }
        saveIndex()
        return note
    }

    /// Start a fresh unsaved note. A scratch with anything in it is saved first, never dropped.
    func newNote(from text: String) {
        if currentNote == nil {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            save(text)
        }
        open(nil)
    }

    /// Edit `id` from now on, or the scratch when it is nothing; the editor is handed the text.
    func open(_ id: UUID?) {
        guard id != index.current else { return }
        let file = id.flatMap { id in index.notes.first { $0.id == id } }.map { url(of: $0) } ?? scratch
        index.current = id
        let text = store.switchTo(file)
        saveIndex()
        onOpen(text)
    }

    /// Rename a note, and its file with it.
    func rename(_ id: UUID, to proposed: String) {
        guard let position = position(of: id) else { return }
        let name = unique(Self.clean(proposed), excluding: id)
        guard !name.isEmpty, name != index.notes[position].name else { return }
        if id == index.current { store.flush() }  // nothing may still be on its way to the old name
        let old = url(of: index.notes[position])
        let file = name + ".md"
        let new = folder.appendingPathComponent(file)
        try? FileManager.default.moveItem(at: old, to: new)
        index.notes[position].name = name
        index.notes[position].file = file
        index.notes[position].modified = Date()
        if id == index.current { store.relocate(to: new) }
        saveIndex()
    }

    func toggleFavorite(_ id: UUID) {
        guard let position = position(of: id) else { return }
        index.notes[position].favorite.toggle()
        saveIndex()
    }

    /// Throw a note away: its file goes to the Trash where that is possible, so even this is recoverable.
    func delete(_ id: UUID) {
        guard let note = note(id) else { return }
        if id == index.current { open(nil) }
        index.notes.removeAll { $0.id == id }
        let file = url(of: note)
        disk.async { @Sendable in
            let manager = FileManager.default
            if (try? manager.trashItem(at: file, resultingItemURL: nil)) == nil { try? manager.removeItem(at: file) }
        }
        saveIndex()
    }

    /// Write one note where the user chose.
    func export(_ note: SavedNote, to destination: URL) throws {
        try text(of: note).write(to: destination, atomically: true, encoding: .utf8)
    }

    /// Write every note into a folder of its own, each under its name, with the index metadata beside them.
    func exportAll(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for note in index.notes {
            try text(of: note).write(to: destination.appendingPathComponent(note.file), atomically: true, encoding: .utf8)
        }
        try Self.coder().encode(index).write(to: destination.appendingPathComponent("index.json"), options: .atomic)
    }

    /// Everything pending, on disk, now.
    func flush() {
        saving?.cancel()
        writeIndex()
        store.flush()
        disk.sync {}
    }

    private func add(name: String, text: String, links: [NoteLink]) -> SavedNote {
        let note = SavedNote(file: name + ".md", name: name, preview: Self.preview(text), links: links)
        index.notes.append(note)
        return note
    }

    private func position(of id: UUID?) -> Int? {
        id.flatMap { id in index.notes.firstIndex { $0.id == id } }
    }

    private func nextName() -> String {
        var number = index.notes.count + 1
        while index.notes.contains(where: { $0.name == "Note \(number)" }) { number += 1 }
        return unique("Note \(number)", excluding: nil)
    }

    /// A name no other note has, and no file in the folder either.
    private func unique(_ name: String, excluding id: UUID?) -> String {
        guard !name.isEmpty else { return name }
        var candidate = name
        var number = 2
        while index.notes.contains(where: { $0.id != id && $0.name == candidate })
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + ".md").path) {
            candidate = "\(name) \(number)"
            number += 1
        }
        return candidate
    }

    /// A name a file can have: one line, no separators, not endless.
    private static func clean(_ name: String) -> String {
        let flattened = name.components(separatedBy: .newlines).joined(separator: " ")
        let safe = flattened.map { "/:".contains($0) ? "-" : $0 }
        return String(String(safe).prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// The first line with anything on it.
    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String((line ?? "").trimmingCharacters(in: .whitespaces).prefix(140))
    }

    private static func coder() -> JSONCoder { JSONCoder() }

    private func saveIndex() {
        saving?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeIndex() }
        }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func writeIndex() {
        guard let data = try? Self.coder().encode(index) else { return }
        let file = indexFile
        disk.async { @Sendable in try? data.write(to: file, options: .atomic) }
    }
}

/// Dates in the index read as dates, not as a count of seconds, so the metadata stays legible wherever it is exported.
private struct JSONCoder {
    func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
