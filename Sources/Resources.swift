import Foundation

/// Everything the app needs from disk to run: its own resources and the `uv` that starts the engine. Launched from
/// Finder there is no shell, so nothing may be looked up through `PATH` alone.
enum AppResources {
    /// The bundle id, and with it the defaults domain and the Keychain service.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.albastov.iridium-live"

    /// Where the engine scripts, the font and the icon live.
    static let directory = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")

    /// The engine's entry point; the modules it imports sit beside it.
    static var engineScript: URL { directory.appendingPathComponent("live.py") }

    static var font: URL { directory.appendingPathComponent("TikTokSans.ttf") }

    /// Where uv is installed, in the order the installers use. The shell's `PATH` is tried last, for a `make run`
    /// from a terminal that keeps it somewhere else.
    static var uv: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appendingPathComponent(".local/bin/uv"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
                          URL(fileURLWithPath: "/usr/local/bin/uv")]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0) + "/uv") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The command that runs the engine, or nothing when uv is missing.
    static func engineCommand(asr: String, wav: String?) -> [String]? {
        guard let uv else { return nil }
        return [uv.path, "run", "--quiet", "--script", engineScript.path, "--asr", asr]
            + (wav.map { ["--wav", $0] } ?? [])
    }

    /// The engine's environment: ours, with the API keys from the Keychain over it and uv's own directory on `PATH`
    /// so the tools it shells out to are found with no login shell behind us.
    static func engineEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let keys = Keychain.shared.values()
        for key in ApiKey.all {
            if let value = keys[key.id] { environment[key.variable] = value }
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if let directory = uv?.deletingLastPathComponent().path, !path.split(separator: ":").contains(Substring(directory)) {
            environment["PATH"] = directory + ":" + path
        }
        // Python would otherwise write __pycache__ beside the scripts, which breaks the bundle's signature.
        environment["PYTHONPYCACHEPREFIX"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/iridium-live/pycache").path
        return environment
    }

    /// What `--check` prints: enough to see why a launch from Finder found nothing.
    static func report() -> String {
        let engine = FileManager.default.fileExists(atPath: engineScript.path) ? engineScript.path : "missing"
        let command = engineCommand(asr: "phonon-2", wav: nil)?.joined(separator: " ") ?? "no uv found"
        return """
            bundle    \(Bundle.main.bundleURL.path)
            id        \(bundleID)
            resources \(directory.path)
            engine    \(engine)
            font      \(FileManager.default.fileExists(atPath: font.path) ? font.path : "missing")
            uv        \(uv?.path ?? "missing")
            command   \(command)
            keys      \(ApiKey.all.map { "\($0.name) \(Keychain.shared.stored().contains($0.id) ? "set" : "unset")" }.joined(separator: ", "))
            """
    }
}
