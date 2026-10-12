import Foundation
import Security

struct Keychain {
    let service: String

    static let shared = Keychain(service: AppResources.bundleID)

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "keys"]
    }

    func stored() -> Set<String> {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let attributes = found as? [String: Any], let names = attributes[kSecAttrGeneric as String] as? Data,
              let text = String(data: names, encoding: .utf8) else { return [] }
        return Set(text.split(separator: ",").map(String.init))
    }

    func values() -> [String: String] {
        read().values
    }

    @discardableResult
    func set(_ value: String?, for id: String) -> OSStatus {
        var (status, values) = read()
        guard status == errSecSuccess || status == errSecItemNotFound else { return status }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        values[id] = text.isEmpty ? nil : text
        guard !values.isEmpty else {
            let deleted = SecItemDelete(item as CFDictionary)
            return deleted == errSecItemNotFound ? errSecSuccess : deleted
        }
        guard let data = try? JSONEncoder().encode(values) else { return errSecParam }
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrGeneric as String: Data(values.keys.sorted().joined(separator: ",").utf8)]
        let update = SecItemUpdate(item as CFDictionary, changes as CFDictionary)
        if update != errSecItemNotFound { return update }
        var insert = item.merging(changes) { $1 }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private func read() -> (status: OSStatus, values: [String: String]) {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return (status, [:]) }
        return (status, values)
    }
}

struct ApiKey: Identifiable, Sendable {
    let id: String
    let name: String
    let variable: String
    let site: String

    static let groq = ApiKey(id: "groq", name: "Groq", variable: "GROQ_API_KEY", site: "console.groq.com/keys")
    static let openRouter = ApiKey(id: "openrouter", name: "OpenRouter", variable: "OPENROUTER_API_KEY",
                                   site: "openrouter.ai/keys")
    static let elevenLabs = ApiKey(id: "elevenlabs", name: "ElevenLabs", variable: "ELEVENLABS_API_KEY",
                                   site: "elevenlabs.io/app/settings/api-keys")
    static let assemblyAI = ApiKey(id: "assemblyai", name: "AssemblyAI", variable: "ASSEMBLYAI_API_KEY",
                                   site: "assemblyai.com/app/api-keys")
    static let deepgram = ApiKey(id: "deepgram", name: "Deepgram", variable: "DEEPGRAM_API_KEY",
                                 site: "console.deepgram.com")
    static let anthropic = ApiKey(id: "anthropic", name: "Anthropic", variable: "ANTHROPIC_API_KEY",
                                  site: "console.anthropic.com/settings/keys")
    static let cleanup = [groq, openRouter]
    static let meeting = [elevenLabs, assemblyAI, deepgram, anthropic]
    static let all = cleanup + meeting

    static func named(_ id: String) -> ApiKey? { all.first { $0.id == id } }
}

