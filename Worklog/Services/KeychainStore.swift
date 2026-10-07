import Foundation
import Security

/// Minimal generic-password Keychain wrapper (one string value per key).
/// Keys used by AuthService: "appleUserID", "appleUserName", "appleUserEmail".
struct KeychainStore {
    let service: String

    init(service: String = AppConstants.bundleID) {
        self.service = service
    }

    /// kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlock; upsert.
    func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.auth.error("Keychain write for \(key, privacy: .public) failed: \(status)")
        }
    }

    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.auth.error("Keychain read for \(key, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.auth.error("Keychain delete for \(key, privacy: .public) failed: \(status)")
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
