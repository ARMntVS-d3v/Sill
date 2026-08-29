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

    // The methods are nonisolated: they hold no state beyond the immutable
    // service name, and callers off the main actor (key migration, presence
    // check) must be able to reach the Keychain without hopping to main —
    // the Keychain blocks whichever thread asks it
    nonisolated func get(_ key: String) -> String? { Self.read(service: service, account: key) }

    #if DEBUG
    // Development builds keep secrets in a file, not the Keychain. Every rebuild
    // changes the binary, and the Keychain answers that with a password prompt —
    // several times a day while working on the app. The file sits next to the config
    // with 0600 permissions and never leaves this machine; release builds are
    // unchanged. The Keychain is still read once, when the file has no such key yet,
    // so a key entered before this change isn't lost
    nonisolated private static let devFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/sill/dev-secrets.json")
    nonisolated private static let devLock = NSLock()

    nonisolated private static func devSecrets() -> [String: String] {
        guard let data = try? Data(contentsOf: devFile),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    nonisolated private static func writeDevSecrets(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        let directory = devFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: devFile, options: .atomic)
        // Readable by this user only: it holds provider keys
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: devFile.path)
    }
    #endif

    /// Same read, but off the main actor. The keychain can show a password
    /// prompt and hold the thread until the person responds: on main that's
    /// a frozen UI. Measured live — 12.7 s of the main thread stuck right
    /// after opening the panel, with no animations or events running the
    /// whole time
    nonisolated func value(for key: String) async -> String? {
        Self.read(service: service, account: key)
    }

    nonisolated private static func read(service: String, account: String) -> String? {
        #if DEBUG
        devLock.lock()
        let stored = devSecrets()["\(service)/\(account)"]
        devLock.unlock()
        if let stored { return stored }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            // "Not found" is a normal answer; anything else (locked keychain,
            // denied access) must at least leave a trace — it used to be
            // indistinguishable from "no key saved"
            if status != errSecItemNotFound {
                sillLog("[secrets] Keychain read failed for \(service)/\(account): \(status)")
            }
            return nil
        }
        let value = String(data: data, encoding: .utf8)
        #if DEBUG
        // Came from the Keychain — remember it in the file, so this is the last
        // time a development build has to ask
        if let value {
            devLock.lock()
            var map = devSecrets()
            map["\(service)/\(account)"] = value
            writeDevSecrets(map)
            devLock.unlock()
        }
        #endif
        return value
    }

    nonisolated func remove(_ key: String) {
        #if DEBUG
        Self.forgetDev(service: service, account: key)
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated func set(_ key: String, _ value: String) {
        #if DEBUG
        Self.devLock.lock()
        var map = Self.devSecrets()
        map["\(service)/\(key)"] = value
        Self.writeDevSecrets(map)
        Self.devLock.unlock()
        return
        #else
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
        #endif
    }

    nonisolated func delete(_ key: String) {
        #if DEBUG
        Self.forgetDev(service: service, account: key)
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    #if DEBUG
    nonisolated private static func forgetDev(service: String, account: String) {
        devLock.lock()
        var map = devSecrets()
        map["\(service)/\(account)"] = nil
        writeDevSecrets(map)
        devLock.unlock()
    }
    #endif
}
