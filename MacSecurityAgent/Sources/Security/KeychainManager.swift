import Foundation
#if canImport(Security)
import Security

/// Generic-password Keychain storage for the bot token and the media key.
///
/// Items are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (never synced to iCloud, never migrated to another Mac). The modern
/// data-protection keychain is used when the app is signed with a team
/// identifier; ad-hoc / "Sign to Run Locally" builds lack the required
/// entitlement (`errSecMissingEntitlement`), in which case the login
/// keychain is used instead.
public final class KeychainManager: SecureStorage {
    public static let defaultService = "com.macsecurityagent.credentials"

    private let service: String
    private let useDataProtectionKeychain = LockedValue<Bool>(true)

    public init(service: String = KeychainManager.defaultService) {
        self.service = service
    }

    public func readData(forKey key: String) throws -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            useDataProtectionKeychain.set(false)
            query = baseQuery(forKey: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecureStorageError.unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStorageError.keychain(status: status)
        }
    }

    public func writeData(_ data: Data, forKey key: String) throws {
        var status = upsert(data, forKey: key)
        if status == errSecMissingEntitlement {
            useDataProtectionKeychain.set(false)
            status = upsert(data, forKey: key)
        }
        guard status == errSecSuccess else { throw SecureStorageError.keychain(status: status) }
    }

    public func deleteData(forKey key: String) throws {
        var status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        if status == errSecMissingEntitlement {
            useDataProtectionKeychain.set(false)
            status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.keychain(status: status)
        }
    }

    private func upsert(_ data: Data, forKey key: String) -> OSStatus {
        let query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        addQuery[kSecAttrLabel as String] = "MacSecurityAgent (\(key))"
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        if useDataProtectionKeychain.current {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
#endif
