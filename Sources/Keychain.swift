import Foundation
import Security

/// The API keys the cleanup models need, kept in the login keychain under the app's bundle id. The installed app has
/// no shell environment, so this is where they come from; the engine is handed them when it starts.
struct Keychain {
    let service: String

    static let shared = Keychain(service: AppResources.bundleID)

    func value(for account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    /// Stores `value` under `account`, replacing what was there; an empty or missing value removes the item.
    /// Returns the keychain's own result, so a failure can be said out loud rather than swallowed.
    @discardableResult
    func set(_ value: String?, for account: String) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(text.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update != errSecItemNotFound { return update }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil)
    }
}

/// One of the keys the user can hold: how it is named on screen, and the variable the engine reads it from.
struct ApiKey: Identifiable, Sendable {
    let id: String        // also the keychain account
    let name: String
    let variable: String
    let site: String

    static let groq = ApiKey(id: "groq", name: "Groq", variable: "GROQ_API_KEY", site: "console.groq.com/keys")
    static let openRouter = ApiKey(id: "openrouter", name: "OpenRouter", variable: "OPENROUTER_API_KEY",
                                   site: "openrouter.ai/keys")
    static let all = [groq, openRouter]
}
