import Foundation
import Security

/// Minimal generic-password Keychain wrapper (one string value per key).
/// Keys used by AuthService: "appleUserID", "appleUserName", "appleUserEmail".
///
/// When the app is signed with a team (it has an application identifier) items live in the data-protection keychain
/// with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (never synced, never in backups of other Macs). Ad-hoc
/// "Sign to Run Locally" builds can't use that keychain, so they fall back to the legacy file-based login keychain.
/// Items found only in the legacy keychain are migrated on first read.
struct KeychainStore {
    let service: String
    private let usesDataProtection: Bool

    /// The bundle identifier of the running app, falling back to `AppConstants.bundleID`.
    static var defaultService: String { Bundle.main.bundleIdentifier ?? AppConstants.bundleID }

    init(service: String = KeychainStore.defaultService) {
        self.service = service
        self.usesDataProtection = Entitlements.hasApplicationIdentifier
    }

    /// kSecClassGenericPassword; upsert.
    func set(_ value: String, for key: String) {
        let status = write(Data(value.utf8), for: key, dataProtection: usesDataProtection)
        if status != errSecSuccess {
            Log.auth.error("Keychain write for \(key, privacy: .public) failed: \(status)")
        }
    }

    func string(for key: String) -> String? {
        let (status, data) = read(key, dataProtection: usesDataProtection)
        if status == errSecSuccess, let data {
            return String(data: data, encoding: .utf8)
        }
        if status != errSecItemNotFound {
            Log.auth.error("Keychain read for \(key, privacy: .public) failed: \(status)")
            return nil
        }
        guard usesDataProtection else { return nil }
        // Migrate an item written by an earlier build to the legacy keychain.
        let (legacyStatus, legacyData) = read(key, dataProtection: false)
        guard legacyStatus == errSecSuccess, let legacyData else { return nil }
        if write(legacyData, for: key, dataProtection: true) == errSecSuccess {
            _ = SecItemDelete(baseQuery(for: key, dataProtection: false) as CFDictionary)
            Log.auth.info("Migrated keychain item \(key, privacy: .public)")
        }
        return String(data: legacyData, encoding: .utf8)
    }

    func delete(_ key: String) {
        var statuses = [SecItemDelete(baseQuery(for: key, dataProtection: usesDataProtection) as CFDictionary)]
        if usesDataProtection {
            statuses.append(SecItemDelete(baseQuery(for: key, dataProtection: false) as CFDictionary))
        }
        for status in statuses where status != errSecSuccess && status != errSecItemNotFound {
            Log.auth.error("Keychain delete for \(key, privacy: .public) failed: \(status)")
        }
    }

    // MARK: - Private

    private func write(_ data: Data, for key: String, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(for: key, dataProtection: dataProtection)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status
    }

    private func read(_ key: String, dataProtection: Bool) -> (OSStatus, Data?) {
        var query = baseQuery(for: key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private func baseQuery(for key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
