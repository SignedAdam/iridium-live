import Foundation

enum Migration {
    private static let oldDomains = ["IridiumLive", "PhononLive"]
    private static let carried = ["settings", "barCenter"]

    static func current(_ path: String) -> String {
        path.replacingOccurrences(of: "/Application Support/PhononLive/", with: "/Application Support/Iridium Live/")
    }

    static func carryOver(to support: URL) {
        let manager = FileManager.default
        let old = support.deletingLastPathComponent().appendingPathComponent("PhononLive")
        if !manager.fileExists(atPath: support.path), manager.fileExists(atPath: old.path) {
            do {
                try manager.moveItem(at: old, to: support)
                try? manager.removeItem(at: support.appendingPathComponent("usage.jsonl"))
            } catch {
                FileHandle.standardError.write(Data("could not move \(old.path) to \(support.path): \(error)\n".utf8))
            }
        }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "settings") == nil else { return }
        for domain in oldDomains {
            guard let saved = UserDefaults(suiteName: domain), saved.object(forKey: "settings") != nil else { continue }
            for key in carried {
                if let value = saved.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            return
        }
    }
}

