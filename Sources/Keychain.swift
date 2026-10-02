import Foundation
import Security

/// The API keys the cleanup models need, kept together as one item in the login keychain under the app's bundle id:
/// one item, so a new build of the app is asked about them once rather than once per key. The installed app has no
/// shell environment, so this is where they come from; the engine is handed them when it starts.
struct Keychain {
    let service: String

    static let shared = Keychain(service: AppResources.bundleID)

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "keys"]
    }

    /// Which keys are stored, read from the item's attributes (which name them): only the secrets themselves are
    /// guarded, so this never brings up the keychain's "wants to use your confidential information" dialog.
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

    /// Every stored key by id, in one read.
    func values() -> [String: String] {
        read().values
    }

    /// Stores `value` under `id` beside the others; an empty or missing value removes it. Returns the keychain's own
    /// result, so a failure can be said out loud rather than swallowed; a refused read writes nothing, so the other
    /// keys are never lost.
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

/// One of the keys the user can hold: how it is named on screen, and the variable the engine reads it from.
struct ApiKey: Identifiable, Sendable {
    let id: String
    let name: String
    let variable: String
    let site: String

    static let groq = ApiKey(id: "groq", name: "Groq", variable: "GROQ_API_KEY", site: "console.groq.com/keys")
    static let openRouter = ApiKey(id: "openrouter", name: "OpenRouter", variable: "OPENROUTER_API_KEY",
                                   site: "openrouter.ai/keys")
    static let all = [groq, openRouter]
}
