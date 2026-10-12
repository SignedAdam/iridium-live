import Foundation

struct MeetingStore {
    let root: URL
    static let fileName = "meeting.json"

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func folder(_ meeting: Meeting) -> URL {
        root.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    func load() -> [Meeting] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [Meeting] = []
        let decoder = Self.decoder
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let file = folder.appendingPathComponent(Self.fileName)
            guard let data = try? Data(contentsOf: file),
                  let meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            out.append(meeting)
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    func save(_ meeting: Meeting) -> Bool {
        let dir = folder(meeting)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(meeting) else { return false }
        let file = dir.appendingPathComponent(Self.fileName)
        do {
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: folder(meeting))
    }

    func folderNames() -> [String] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return folders.compactMap {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) ? $0.lastPathComponent : nil
        }
    }
}
