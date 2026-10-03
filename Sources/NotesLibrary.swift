import Foundation

struct NoteLink: Codable, Equatable, Sendable {
    let entry: UUID
    var audio: [AudioRef]?
}

struct SavedNote: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var file: String
    var name: String
    var created = Date()
    var modified = Date()
    var favorite = false
    var preview = ""
    var links: [NoteLink] = []
}

@MainActor @Observable
final class NotesLibrary {
    private struct Index: Codable {
        var notes: [SavedNote] = []
        var scratch: [NoteLink] = []
        var current: UUID?
    }

    static let scratchName = "Unsaved"
    private static let settle = 0.3

    let folder: URL
    let store: NotesStore
    private let indexFile: URL
    private let scratch: URL
    private let disk = DispatchQueue(label: "notes.library")
    private var index: Index
    private var saving: DispatchWorkItem?

    @ObservationIgnored var onOpen: (String) -> Void = { _ in }

    var naming: UUID?

    init(directory: URL) {
        let notes = directory.appendingPathComponent("Notes")
        folder = notes
        indexFile = notes.appendingPathComponent("index.json")
        scratch = directory.appendingPathComponent("notes.txt")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        var loaded = (try? Data(contentsOf: notes.appendingPathComponent("index.json")))
            .flatMap { try? Self.coder().decode(Index.self, from: $0) } ?? Index()
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

    var initialText: String { store.initialText }

    var notes: [SavedNote] { index.notes }

    var sorted: [SavedNote] {
        index.notes.sorted { $0.favorite == $1.favorite ? $0.modified > $1.modified : $0.favorite }
    }

    var currentNote: SavedNote? { index.current.flatMap { id in index.notes.first { $0.id == id } } }

    var currentName: String { currentNote?.name ?? Self.scratchName }

    func note(_ id: UUID) -> SavedNote? { index.notes.first { $0.id == id } }

    func url(of note: SavedNote) -> URL { folder.appendingPathComponent(note.file) }

    func text(of note: SavedNote) -> String {
        note.id == index.current ? store.latest : NotesStore.read(url(of: note))
    }

    func changed(_ text: String) {
        store.changed(text)
        guard let position = position(of: index.current) else { return }
        index.notes[position].modified = Date()
        index.notes[position].preview = Self.preview(text)
        saveIndex()
    }

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

    @discardableResult
    func save(_ text: String) -> SavedNote {
        if let note = currentNote { return note }
        let note = add(name: nextName(), text: text, links: index.scratch)
        index.scratch = []
        index.current = note.id
        store.move(to: url(of: note))
        saveIndex()
        return note
    }

    @discardableResult
    func saveSelection(_ text: String) -> SavedNote {
        let note = add(name: nextName(), text: text, links: [])
        let file = url(of: note)
        disk.async { @Sendable in try? text.write(to: file, atomically: true, encoding: .utf8) }
        saveIndex()
        return note
    }

    func newNote(from text: String) {
        if currentNote == nil {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            save(text)
        }
        open(nil)
    }

    func open(_ id: UUID?) {
        guard id != index.current else { return }
        let file = id.flatMap { id in index.notes.first { $0.id == id } }.map { url(of: $0) } ?? scratch
        index.current = id
        let text = store.switchTo(file)
        saveIndex()
        onOpen(text)
    }

    func rename(_ id: UUID, to proposed: String) {
        guard let position = position(of: id) else { return }
        let name = unique(Self.clean(proposed), excluding: id)
        guard !name.isEmpty, name != index.notes[position].name else { return }
        if id == index.current { store.flush() }
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

    func export(_ note: SavedNote, to destination: URL) throws {
        try text(of: note).write(to: destination, atomically: true, encoding: .utf8)
    }

    func exportAll(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for note in index.notes {
            try text(of: note).write(to: destination.appendingPathComponent(note.file), atomically: true, encoding: .utf8)
        }
        try Self.coder().encode(index).write(to: destination.appendingPathComponent("index.json"), options: .atomic)
    }

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

    private static func clean(_ name: String) -> String {
        let flattened = name.components(separatedBy: .newlines).joined(separator: " ")
        let safe = flattened.map { "/:".contains($0) ? "-" : $0 }
        return String(String(safe).prefix(80)).trimmingCharacters(in: .whitespaces)
    }

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

