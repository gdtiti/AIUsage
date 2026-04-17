import Foundation
import Combine
import QuotaBackend

extension AccountStore {
    // MARK: - Account matching & lookup
    //
    // These are thin delegates to `AccountIdentityPolicy` — the single source of
    // truth for identity / matching rules (see AccountStore+Persistence.swift).
    // Keep the instance-method surface so existing callers throughout the app
    // stay unchanged; the logic is centralized in the policy.

    func bestCredentialMatch(
        for account: StoredProviderAccount,
        candidates: [AccountCredential]
    ) -> AccountCredential? {
        AccountIdentityPolicy.bestCredentialMatch(for: account, candidates: candidates)
    }

    func bestStoredAccountIndex(
        for provider: ProviderData,
        excluding reservedStoredIDs: Set<String>,
        allowUnseenCredentialFallback: Bool
    ) -> Int? {
        AccountIdentityPolicy.bestStoredAccountIndex(
            in: accountRegistry,
            for: provider,
            excluding: reservedStoredIDs,
            allowUnseenCredentialFallback: allowUnseenCredentialFallback
        )
    }

    func storedAccountMatchesLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        AccountIdentityPolicy.matchesLive(stored: stored, provider: provider)
    }

    func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        AccountIdentityPolicy.normalizedLiveAccountID(for: provider)
    }

    func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        AccountIdentityPolicy.normalizedAccountIdentifier(for: provider)
    }

    func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        AccountIdentityPolicy.providerSort(lhs, rhs, catalogOrder: providerCatalogOrder)
    }

    // MARK: - Entry-scoped lookups (not duplicated in the worker snapshot)

    func bestStoredAccountIndex(for entry: ProviderAccountEntry) -> Int? {
        if let storedID = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedID }) {
            return exactIndex
        }

        if let liveProvider = entry.liveProvider,
           let liveIndex = accountRegistry.firstIndex(where: {
               AccountIdentityPolicy.matchesLive(stored: $0, provider: liveProvider)
           }) {
            return liveIndex
        }

        // Codex multi-workspace: same email can legitimately belong to different workspaces.
        // Only allow stable-identifier fallback (credentialId / accountId), never email alone.
        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            let stableTokens = Set([
                entry.storedAccount?.credentialId?.lowercased().nilIfBlank,
                entry.storedAccount?.normalizedAccountId,
                entry.liveProvider?.accountId?.lowercased().nilIfBlank
            ].compactMap { $0 })
            guard !stableTokens.isEmpty else { return nil }
            return accountRegistry.firstIndex { stored in
                guard stored.providerId == entry.providerId else { return false }
                let storedStable = Set([
                    stored.credentialId?.lowercased().nilIfBlank,
                    stored.normalizedAccountId
                ].compactMap { $0 })
                return !stableTokens.isDisjoint(with: storedStable)
            }
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

    func matchingCredentialsImpl(for entry: ProviderAccountEntry) -> [AccountCredential] {
        if let credentialId = entry.storedAccount?.credentialId?.nilIfBlank,
           let directMatch = AccountCredentialStore.shared.loadCredential(
            providerId: entry.providerId,
            credentialId: credentialId
           ) {
            return [directMatch]
        }

        let credentials = AccountCredentialStore.shared.loadCredentials(for: entry.providerId)

        // Codex: credentialId path above is the only safe direct match.
        // For token fallback, require stable identifier (accountId) — email alone
        // would cross-match different workspaces sharing the same login email.
        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            let stableTokens = Set([
                entry.storedAccount?.normalizedAccountId,
                entry.liveProvider?.accountId?.lowercased().nilIfBlank
            ].compactMap { $0 })
            guard !stableTokens.isEmpty else { return [] }
            return credentials.filter { credential in
                guard let credAccountId = credential.metadata["accountId"]?.lowercased().nilIfBlank else {
                    return false
                }
                return stableTokens.contains(credAccountId)
            }
        }

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
            for (index, stored) in accountRegistry.enumerated() where
                AccountIdentityPolicy.matchesLive(stored: stored, provider: liveProvider) {
                indices.insert(index)
            }
        }

        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            // Codex: restrict to stable identifiers so deletion cannot fan out by email.
            let stableTokens = Set([
                entry.storedAccount?.credentialId?.lowercased().nilIfBlank,
                entry.storedAccount?.normalizedAccountId,
                entry.liveProvider?.accountId?.lowercased().nilIfBlank
            ].compactMap { $0 })
            if !stableTokens.isEmpty {
                for (index, stored) in accountRegistry.enumerated() where stored.providerId == entry.providerId {
                    let storedStable = Set([
                        stored.credentialId?.lowercased().nilIfBlank,
                        stored.normalizedAccountId
                    ].compactMap { $0 })
                    if !stableTokens.isDisjoint(with: storedStable) {
                        indices.insert(index)
                    }
                }
            }
            return indices.sorted()
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
}
