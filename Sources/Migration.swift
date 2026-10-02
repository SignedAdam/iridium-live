import Foundation

/// The app used to be called PhononLive. On the first launch under the new name, everything it kept comes along:
/// the data folder (notes, saved notes, history, journal, backups, recordings) is moved, not copied, and the
/// settings and the control's position are carried over. The token usage log is rebuilt from the history under the
/// new source name, so the ledger never sees the old one.
enum Migration {
    private static let oldDomains = ["PhononLive"]
    private static let carried = ["settings", "barCenter"]

    static func fromPhononLive(to support: URL) {
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
