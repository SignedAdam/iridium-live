import Foundation

public enum ManifestStore {
    public static let fileName = "manifest.json"

    public static func manifestURL(inSessionFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    public static func write(_ manifest: RecordingManifest, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder().encode(manifest)
        try data.write(to: manifestURL(inSessionFolder: folder), options: .atomic)
    }

    public static func read(from folder: URL) throws -> RecordingManifest {
        let data = try Data(contentsOf: manifestURL(inSessionFolder: folder))
        return try decoder().decode(RecordingManifest.self, from: data)
    }

    public static func readIfPresent(from folder: URL) -> RecordingManifest? {
        try? read(from: folder)
    }

    public static func scanForInterruptedSessions(in root: URL) -> [(folder: URL, manifest: RecordingManifest)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [(URL, RecordingManifest)] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, let manifest = readIfPresent(from: entry), manifest.isInterrupted else { continue }
            result.append((entry, manifest))
        }
        return result.sorted { $0.1.startedAt < $1.1.startedAt }
    }
}
