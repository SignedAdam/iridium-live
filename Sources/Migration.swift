import Foundation

/// The app used to be called PhononLive, and until it was bundled it kept its settings under `IridiumLive` rather
/// than its bundle id. On the first launch of the bundle, everything either of them kept comes along: the data
/// folder (notes, saved notes, history, journal, backups, recordings) is moved, not copied, and the settings and the
/// control's position are carried over from the newer of the two domains. The token usage log is rebuilt from the
/// history under the new source name, so the ledger never sees the old one.
enum Migration {
    private static let oldDomains = ["IridiumLive", "PhononLive"]
    private static let carried = ["settings", "barCenter"]

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
