import Foundation
import Security
import os.log

private let vaultLog = Logger(subsystem: "com.aiusage.desktop", category: "SecureAccountVault")

final class SecureAccountVault {
    static let shared = SecureAccountVault()

    private let service = "com.aiusage.desktop.providerAccounts"
    private let account = "registry"

    private init() {}

    func loadAccounts() -> [StoredProviderAccount] {
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
            vaultLog.error("Keychain read failed: \(msg)")
        }

        guard status == errSecSuccess,
              let data = item as? Data,
              let accounts = try? JSONDecoder().decode([StoredProviderAccount].self, from: data) else {
            return []
        }

        return accounts
    }

    func saveAccounts(_ accounts: [StoredProviderAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
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
            return
        }

        guard status == errSecSuccess else {
            throw VaultError.osStatus(status)
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
