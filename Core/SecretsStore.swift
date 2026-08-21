import Foundation
import Security

// Widget secrets (API keys, tokens): Keychain, not UserDefaults, not config.
// Generic password: service = "app.sill.widget.<widgetID>", account = key.
@MainActor
final class SecretsStore {
    nonisolated let service: String

    init(widgetID: String) {
        service = "app.sill.widget.\(widgetID)"
    }

    func get(_ key: String) -> String? { Self.read(service: service, account: key) }

    /// Same read, but off the main actor. The keychain can show a password
    /// prompt and hold the thread until the person responds: on main that's
    /// a frozen UI. Measured live — 12.7 s of the main thread stuck right
    /// after opening the panel, with no animations or events running the
    /// whole time
    nonisolated func value(for key: String) async -> String? {
        Self.read(service: service, account: key)
    }

    nonisolated private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
