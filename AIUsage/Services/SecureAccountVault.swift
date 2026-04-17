import Foundation
import Security
import os.log

private let vaultLog = Logger(subsystem: "com.aiusage.desktop", category: "SecureAccountVault")

final class SecureAccountVault: @unchecked Sendable {
    nonisolated static let shared = SecureAccountVault()

    private let service = "com.aiusage.desktop.providerAccounts"
    private let account = "registry"

    private init() {}

    // MARK: - Public API

    nonisolated func loadAccounts() -> [StoredProviderAccount] {
        if let data = readFromDataProtectionKeychain() {
            return decodeAccounts(data)
        }
        if let data = readFromLegacyKeychain() {
            let accounts = decodeAccounts(data)
            migrateToDataProtectionKeychain(data)
            return accounts
        }
        return []
    }

    nonisolated func saveAccounts(_ accounts: [StoredProviderAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        do {
            try writeToDataProtectionKeychain(data)
        } catch {
            vaultLog.warning("DP Keychain write failed, falling back to legacy: \(error.localizedDescription, privacy: .public)")
            try writeToLegacyKeychain(data)
        }
    }

    // MARK: - Data Protection Keychain

    private func dataProtectionQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func readFromDataProtectionKeychain() -> Data? {
        var query = dataProtectionQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func writeToDataProtectionKeychain(_ data: Data) throws {
        let base = dataProtectionQuery()
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = base
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VaultError.osStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw VaultError.osStatus(status)
        }
    }

    // MARK: - Legacy Keychain

    private func readFromLegacyKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status != errSecSuccess && status != errSecItemNotFound {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            vaultLog.error("Legacy keychain read failed: \(msg)")
        }

        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func writeToLegacyKeychain(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = baseQuery
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VaultError.osStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw VaultError.osStatus(status)
        }
    }

    private func deleteLegacyKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func migrateToDataProtectionKeychain(_ data: Data) {
        do {
            try writeToDataProtectionKeychain(data)
            deleteLegacyKeychainItem()
            vaultLog.info("Migrated account registry to Data Protection Keychain")
        } catch {
            vaultLog.warning("DP migration skipped (entitlement missing?), using legacy keychain")
        }
    }

    // MARK: - Helpers

    private func decodeAccounts(_ data: Data) -> [StoredProviderAccount] {
        do {
            return try JSONDecoder().decode([StoredProviderAccount].self, from: data)
        } catch {
            vaultLog.error("Account registry decode failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

enum VaultError: LocalizedError {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error: \(status)"
        }
    }
}
