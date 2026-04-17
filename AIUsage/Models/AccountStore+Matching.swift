import Foundation
import Combine
import QuotaBackend

extension AccountStore {
    private static let multiWorkspaceProviders: Set<String> = ["codex"]

    // MARK: - Account matching & lookup

    func bestCredentialMatch(
        for account: StoredProviderAccount,
        candidates: [AccountCredential]
    ) -> AccountCredential? {
        let normalizedAccountId = account.normalizedAccountId
        if let normalizedAccountId,
           let accountIDMatch = candidates.first(where: {
               normalizedAccountLookupValue($0.metadata["accountId"]) == normalizedAccountId
           }) {
            return accountIDMatch
        }

        if !account.normalizedEmail.isEmpty,
           let emailMatch = candidates.first(where: {
               let credAccountId = normalizedAccountLookupValue($0.metadata["accountId"])
               if let normalizedAccountId, let credAccountId, credAccountId != normalizedAccountId {
                   return false
               }
               return normalizedAccountLookupValue(
                   $0.metadata["accountEmail"]
                       ?? $0.metadata["accountHandle"]
                       ?? $0.accountLabel
               ) == account.normalizedEmail
           }) {
            return emailMatch
        }

        return nil
    }

    func bestStoredAccountIndex(
        for provider: ProviderData,
        excluding reservedStoredIDs: Set<String>,
        allowUnseenCredentialFallback: Bool
    ) -> Int? {
        let liveAccountId = normalizedLiveAccountID(for: provider)
        if let liveAccountId {
            if let accountIdMatch = accountRegistry.firstIndex(where: {
                !reservedStoredIDs.contains($0.id) && !$0.isHidden &&
                $0.providerId == provider.baseProviderId &&
                $0.normalizedAccountId == liveAccountId
            }) {
                return accountIdMatch
            }
        }

        if let exactIndex = accountRegistry.firstIndex(where: {
            !reservedStoredIDs.contains($0.id) && !$0.isHidden && storedAccountMatchesLive($0, provider: provider)
        }) {
            return exactIndex
        }

        guard allowUnseenCredentialFallback,
              extractCredentialId(from: provider.id) != nil else {
            return nil
        }

        let fallbackCandidates = accountRegistry.enumerated().filter { _, stored in
            !reservedStoredIDs.contains(stored.id) &&
            stored.providerId == provider.baseProviderId &&
            !stored.isHidden &&
            stored.credentialId != nil &&
            stored.lastSeenAt == nil
        }

        guard fallbackCandidates.count == 1 else { return nil }
        return fallbackCandidates[0].offset
    }

    func storedAccountMatchesLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        guard stored.providerId == provider.baseProviderId else { return false }

        if let credentialId = stored.credentialId?.nilIfBlank {
            let expectedId = "\(stored.providerId):cred:\(credentialId)"
            if provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(expectedId) == .orderedSame {
                return true
            }
        }

        if let storedResultId = stored.normalizedProviderResultId {
            let liveId = provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if storedResultId == liveId {
                return true
            }
            if liveId.hasPrefix(storedResultId + ":") || storedResultId.hasPrefix(liveId + ":") {
                return true
            }
        }

        if let storedAccountId = stored.normalizedAccountId,
           let liveAccountId = normalizedLiveAccountID(for: provider) {
            if storedAccountId == liveAccountId {
                if Self.multiWorkspaceProviders.contains(stored.providerId.lowercased()) {
                    let liveEmail = normalizedAccountIdentifier(for: provider)
                    if let liveEmail, !stored.normalizedEmail.isEmpty {
                        return stored.normalizedEmail == liveEmail
                    }
                }
                return true
            }
            if Self.multiWorkspaceProviders.contains(stored.providerId.lowercased()) {
                let liveEmail = normalizedAccountIdentifier(for: provider)
                if let liveEmail, !stored.normalizedEmail.isEmpty,
                   stored.normalizedEmail == liveEmail {
                    return true
                }
            }
            return false
        }

        if let liveEmail = normalizedAccountIdentifier(for: provider),
           stored.normalizedEmail == liveEmail {
            return true
        }

        return false
    }

    func bestStoredAccountIndex(for entry: ProviderAccountEntry) -> Int? {
        if let storedID = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedID }) {
            return exactIndex
        }

        if let liveProvider = entry.liveProvider,
           let liveIndex = accountRegistry.firstIndex(where: { storedAccountMatchesLive($0, provider: liveProvider) }) {
            return liveIndex
        }

        let normalizedTokens = Set([
            entry.accountEmail?.lowercased().nilIfBlank,
            entry.accountDisplayName?.lowercased().nilIfBlank,
            entry.liveProvider?.accountId?.lowercased().nilIfBlank,
            entry.storedAccount?.normalizedEmail,
            entry.storedAccount?.normalizedAccountId
        ].compactMap { $0 })

        guard !normalizedTokens.isEmpty else { return nil }
        return accountRegistry.firstIndex { stored in
            guard stored.providerId == entry.providerId else { return false }
            return normalizedTokens.contains(stored.normalizedEmail)
                || (stored.normalizedAccountId.map(normalizedTokens.contains) ?? false)
        }
    }

    func makeStoredAccount(
        from entry: ProviderAccountEntry,
        note: String?,
        isHidden: Bool,
        lastSeenAt: String?
    ) -> StoredProviderAccount? {
        let now = SharedFormatters.iso8601String(from: Date())
        let label = entry.accountEmail?.nilIfBlank
            ?? entry.accountDisplayName?.nilIfBlank
            ?? entry.liveProvider?.accountId?.nilIfBlank
            ?? entry.storedAccount?.email.nilIfBlank
            ?? entry.providerTitle.nilIfBlank

        guard let label else { return nil }

        return StoredProviderAccount(
            id: entry.storedAccount?.id ?? UUID().uuidString,
            providerId: entry.providerId,
            email: label,
            displayName: entry.storedAccount?.displayName?.nilIfBlank ?? entry.accountDisplayName?.nilIfBlank,
            note: note,
            accountId: entry.liveProvider?.accountId?.nilIfBlank ?? entry.storedAccount?.accountId,
            providerResultId: entry.liveProvider?.id ?? entry.storedAccount?.providerResultId,
            credentialId: entry.storedAccount?.credentialId,
            createdAt: entry.storedAccount?.createdAt ?? now,
            lastSeenAt: lastSeenAt ?? entry.storedAccount?.lastSeenAt,
            isHidden: isHidden
        )
    }

    func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        guard let raw = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    func matchingCredentialsImpl(for entry: ProviderAccountEntry) -> [AccountCredential] {
        if let credentialId = entry.storedAccount?.credentialId?.nilIfBlank,
           let directMatch = AccountCredentialStore.shared.loadCredential(
            providerId: entry.providerId,
            credentialId: credentialId
           ) {
            return [directMatch]
        }

        let credentials = AccountCredentialStore.shared.loadCredentials(for: entry.providerId)
        let identityTokens = accountIdentityTokens(for: entry)
        guard !identityTokens.isEmpty else { return [] }
        return credentials.filter { credential in
            let credentialTokens = Set([
                credential.metadata["accountId"]?.lowercased().nilIfBlank,
                credential.metadata["accountEmail"]?.lowercased().nilIfBlank,
                credential.metadata["accountHandle"]?.lowercased().nilIfBlank,
                credential.accountLabel?.lowercased().nilIfBlank
            ].compactMap { $0 })
            return !identityTokens.isDisjoint(with: credentialTokens)
        }
    }

    func matchingStoredAccountIndices(for entry: ProviderAccountEntry) -> [Int] {
        var indices = Set<Int>()

        if let storedId = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedId }) {
            indices.insert(exactIndex)
        }

        if let liveProvider = entry.liveProvider {
            for (index, stored) in accountRegistry.enumerated() where storedAccountMatchesLive(stored, provider: liveProvider) {
                indices.insert(index)
            }
        }

        let identityTokens = accountIdentityTokens(for: entry)
        if !identityTokens.isEmpty {
            for (index, stored) in accountRegistry.enumerated() where stored.providerId == entry.providerId {
                let storedTokens = Set([
                    stored.normalizedEmail.nilIfBlank,
                    stored.normalizedAccountId,
                    stored.displayName?.lowercased().nilIfBlank,
                    stored.credentialId?.lowercased().nilIfBlank
                ].compactMap { $0 })
                if !identityTokens.isDisjoint(with: storedTokens) {
                    indices.insert(index)
                }
            }
        }

        return indices.sorted()
    }

    func accountIdentityTokens(for entry: ProviderAccountEntry) -> Set<String> {
        Set([
            entry.storedAccount?.normalizedEmail.nilIfBlank,
            entry.storedAccount?.normalizedAccountId,
            entry.storedAccount?.displayName?.lowercased().nilIfBlank,
            entry.storedAccount?.credentialId?.lowercased().nilIfBlank,
            entry.accountEmail?.lowercased().nilIfBlank,
            entry.accountDisplayName?.lowercased().nilIfBlank,
            entry.liveProvider?.accountId?.lowercased().nilIfBlank,
            entry.liveProvider?.accountLabel?.lowercased().nilIfBlank
        ].compactMap { $0 })
    }

    func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let providerOrder = providerCatalogOrder
        let lhsProviderIndex = providerOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsProviderIndex = providerOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsProviderIndex != rhsProviderIndex {
            return lhsProviderIndex < rhsProviderIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }
}
