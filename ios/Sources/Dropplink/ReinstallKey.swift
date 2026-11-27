import Foundation
#if canImport(Security)
import Security
#endif

/// Spec §4 `reinstallKey`: a random UUID kept in the Keychain. Unlike the install id (UserDefaults), a
/// Keychain item survives the app being deleted, so the server can tell a reinstall from a new user and
/// leave it out of billing. This device only (`…ThisDeviceOnly`, not synchronizable): it never moves to
/// another phone through iCloud Keychain or a backup restore. It identifies nothing outside this app; the
/// server stores only a hash scoped to the app.
enum ReinstallKey {
    static let service = "app.ondropp.dropplink"
    static let account = "reinstallKey"

    /// The stored key, creating it on first use. `nil` when the Keychain can't be used (before the first
    /// unlock after a reboot, or a broken entitlement); init is then sent without it.
    static func loadOrCreate() -> String? {
        #if canImport(Security)
        if let existing = read() { return existing }
        let created = UUID().uuidString.lowercased()
        switch add(created) {
        case errSecSuccess: return created
        // Another thread (or an extension sharing the access group) added one first: use theirs.
        case errSecDuplicateItem: return read()
        default: return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(Security)
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil
        else { return nil }
        return value
    }

    private static func add(_ value: String) -> OSStatus {
        var item = baseQuery
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }
    #endif
}
