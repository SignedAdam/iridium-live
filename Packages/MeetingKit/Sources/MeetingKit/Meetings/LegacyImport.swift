import Foundation
import SQLite3

enum LegacyImport {
    static func run(from oldSupport: URL, into store: MeetingStore) -> Int {
        let recordings = oldSupport.appendingPathComponent("Recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordings.path) else { return 0 }

        let existing = store.load()
        var knownIDs = Set(existing.map(\.id))
        var knownFolders = Set(existing.map(\.folderName))
        var imported = 0
        var claimed = Set<String>()

        for row in readRows(from: oldSupport) {
            claimed.insert(row.folderName)
            if knownIDs.contains(row.id) || knownFolders.contains(row.folderName) { continue }
            guard copyFolder(row.folderName, from: recordings, to: store.root) else { continue }
            let meeting = Meeting(
                id: row.id,
                title: row.title,
                startedAt: row.startedAt,
                duration: row.duration,
                folderName: row.folderName,
                hasMic: row.hasMic,
                hasSystem: row.hasSystem,
                engineID: row.engineID,
                state: Meeting.State(rawValue: row.state) ?? .none,
                error: row.error,
                createdAt: row.createdAt,
                isArchived: row.isArchived,
                transcript: decode(row.transcriptData),
                summary: decode(row.summaryData),
                chat: decode(row.chatData) ?? [],
                speakerNames: decode(row.speakerNameData) ?? [:]
            )
            store.save(meeting)
            knownIDs.insert(meeting.id)
            knownFolders.insert(meeting.folderName)
            imported += 1
        }

        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = folder.lastPathComponent
            if claimed.contains(name) || knownFolders.contains(name) { continue }
            guard let manifest = try? ManifestStore.read(from: folder), manifest.duration > 0.3 else { continue }
            guard copyFolder(name, from: recordings, to: store.root) else { continue }
            let meeting = Meeting(
                title: Meeting.defaultTitle(for: manifest.startedAt),
                startedAt: manifest.startedAt,
                duration: manifest.duration,
                folderName: name,
                hasMic: manifest.stream(.mic)?.segments.isEmpty == false,
                hasSystem: manifest.stream(.system)?.segments.isEmpty == false
            )
            store.save(meeting)
            knownFolders.insert(name)
            imported += 1
        }
        return imported
    }

    private static func copyFolder(_ name: String, from recordings: URL, to root: URL) -> Bool {
        let source = recordings.appendingPathComponent(name, isDirectory: true)
        let destination = root.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return false }
        if FileManager.default.fileExists(atPath: destination.path) { return true }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    struct Row {
        var id: UUID
        var title: String
        var folderName: String
        var startedAt: Date
        var createdAt: Date
        var duration: TimeInterval
        var hasMic: Bool
        var hasSystem: Bool
        var engineID: String?
        var state: String
        var error: String?
        var isArchived: Bool
        var transcriptData: Data?
        var summaryData: Data?
        var chatData: Data?
        var speakerNameData: Data?
    }

    static func readRows(from oldSupport: URL) -> [Row] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("MeetingKit-legacy-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: temp, withIntermediateDirectories: true)) != nil else { return [] }
        defer { try? fm.removeItem(at: temp) }

        let store = oldSupport.appendingPathComponent("Iridium.store")
        guard fm.fileExists(atPath: store.path) else { return [] }
        let copy = temp.appendingPathComponent("Iridium.store")
        guard (try? fm.copyItem(at: store, to: copy)) != nil else { return [] }
        for suffix in ["-wal", "-shm"] {
            let side = oldSupport.appendingPathComponent("Iridium.store\(suffix)")
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: temp.appendingPathComponent("Iridium.store\(suffix)"))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ZID, ZTITLE, ZSESSIONFOLDERNAME, ZSTARTEDAT, ZCREATEDAT, ZDURATION, ZHASMIC, ZHASSYSTEM, \
        ZENGINEID, ZTRANSCRIPTIONSTATERAW, ZTRANSCRIPTIONERROR, ZISARCHIVED, ZTRANSCRIPTDATA, ZSUMMARYDATA, \
        ZCHATDATA, ZSPEAKERNAMEDATA FROM ZMEETINGRECORD
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuid(statement, 0), let folder = text(statement, 2), !folder.isEmpty else { continue }
            rows.append(Row(
                id: id,
                title: text(statement, 1) ?? "Meeting",
                folderName: folder,
                startedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
                duration: sqlite3_column_double(statement, 5),
                hasMic: sqlite3_column_int(statement, 6) != 0,
                hasSystem: sqlite3_column_int(statement, 7) != 0,
                engineID: text(statement, 8),
                state: text(statement, 9) ?? "none",
                error: text(statement, 10),
                isArchived: sqlite3_column_int(statement, 11) != 0,
                transcriptData: blob(statement, 12),
                summaryData: blob(statement, 13),
                chatData: blob(statement, 14),
                speakerNameData: blob(statement, 15)
            ))
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: c)
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func uuid(_ statement: OpaquePointer, _ index: Int32) -> UUID? {
        guard let data = blob(statement, index), data.count == 16 else { return nil }
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &bytes) { raw in
            data.copyBytes(to: raw.bindMemory(to: UInt8.self))
        }
        return UUID(uuid: bytes)
    }
}
