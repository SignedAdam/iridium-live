import Foundation

enum AppResources {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.albastov.iridium-live"

    static let directory = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")

    static var engineScript: URL { directory.appendingPathComponent("live.py") }

    static var font: URL { directory.appendingPathComponent("TikTokSans.ttf") }

    static var uv: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appendingPathComponent(".local/bin/uv"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
                          URL(fileURLWithPath: "/usr/local/bin/uv")]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0) + "/uv") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func engineCommand(asr: String, wav: String?) -> [String]? {
        guard let uv else { return nil }
        return [uv.path, "run", "--quiet", "--script", engineScript.path, "--asr", asr]
            + (wav.map { ["--wav", $0] } ?? [])
    }

    static func engineEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let keys = Keychain.shared.values()
        for key in ApiKey.cleanup {
            if let value = keys[key.id] { environment[key.variable] = value }
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if let directory = uv?.deletingLastPathComponent().path, !path.split(separator: ":").contains(Substring(directory)) {
            environment["PATH"] = directory + ":" + path
        }
        environment["PYTHONPYCACHEPREFIX"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/iridium-live/pycache").path
        return environment
    }

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

