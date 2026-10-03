import Foundation

public struct CatalogCache: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func save(_ catalog: Catalog) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(catalog).write(to: url, options: .atomic)
    }

    public func load() -> Catalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Catalog.self, from: data)
    }

    public var age: TimeInterval? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return nil }
        return Date().timeIntervalSince(date)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
