import Foundation
import Combine
import QuotaBackend

extension AccountStore {
    // MARK: - Persistence & normalization

    func normalizePersistedState() {
        bootstrapCredentialIndexFromRegistry()
        let credentialRemapping = AccountCredentialStore.shared.deduplicateCredentials()
        var didChange = applyCredentialRemapping(credentialRemapping)
        if normalizeAccountRegistryAgainstCredentials() {
            didChange = true
        }

        let beforeDedup = accountRegistry.count
        deduplicateAccountRegistry()
        if accountRegistry.count != beforeDedup {
            didChange = true
        }

        if didChange {
            persistAccountRegistry()
        }

        cleanupManagedCredentialArtifacts()
    }

    @discardableResult
    func applyCredentialRemapping(_ remappedCredentialIDs: [String: String]) -> Bool {
        guard !remappedCredentialIDs.isEmpty else { return false }

        var didChange = false
        for index in accountRegistry.indices {
            var updated = accountRegistry[index]

            if let credentialId = updated.credentialId,
               let canonicalID = remappedCredentialIDs[credentialId],
               canonicalID != credentialId {
                updated.credentialId = canonicalID
                didChange = true
            }

            if let providerResultId = updated.providerResultId,
               let resultCredentialId = extractCredentialId(from: providerResultId),
               let canonicalID = remappedCredentialIDs[resultCredentialId],
               canonicalID != resultCredentialId {
                updated.providerResultId = "\(updated.providerId):cred:\(canonicalID)"
                didChange = true
            }

            accountRegistry[index] = updated
        }

        return didChange
    }

    func normalizedAccountLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func existingAuthenticatedCredential(
        providerId: String,
        accountHandle: String,
        accountId: String?,
        sessionFingerprint: String?,
        sourceIdentifier: String?,
        sourceIdentifierIsStable: Bool
    ) -> AccountCredential? {
        let normalizedHandle = normalizedAccountLookupValue(accountHandle)
        let normalizedAccountId = normalizedAccountLookupValue(accountId)
        let normalizedFingerprint = normalizedAccountLookupValue(sessionFingerprint)
        let normalizedSourceIdentifier = normalizedAccountLookupValue(sourceIdentifier)

        return AccountCredentialStore.shared.loadCredentials(for: providerId).first { credential in
            if sourceIdentifierIsStable,
               let normalizedSourceIdentifier,
               credential.metadata["identityScope"] == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue,
               normalizedAccountLookupValue(credential.metadata["sourceIdentifier"]) == normalizedSourceIdentifier {
                return true
            }

            if let normalizedFingerprint,
               normalizedAccountLookupValue(credential.metadata["sessionFingerprint"]) == normalizedFingerprint {
                return true
            }

            if let normalizedAccountId,
               normalizedAccountLookupValue(credential.metadata["accountId"]) == normalizedAccountId {
                return true
            }

            return normalizedAccountLookupValue(
                credential.metadata["accountEmail"]
                    ?? credential.metadata["accountHandle"]
                    ?? credential.accountLabel
            ) == normalizedHandle
        }
    }

    func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    struct CredentialAccountSnapshot {
        let accountHandle: String?
        let displayName: String?
        let accountId: String?
        let validatedAt: String?

        var normalizedAccountId: String? {
            accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
        }
    }

    func credentialAccountSnapshot(providerId: String, credentialId: String) -> CredentialAccountSnapshot? {
        guard let credential = AccountCredentialStore.shared
            .loadCredential(providerId: providerId, credentialId: credentialId) else {
            return nil
        }

        return CredentialAccountSnapshot(
            accountHandle: credential.metadata["accountEmail"]?.nilIfBlank
                ?? credential.metadata["accountHandle"]?.nilIfBlank
                ?? credential.accountLabel?.nilIfBlank,
            displayName: credential.metadata["displayName"]?.nilIfBlank,
            accountId: credential.metadata["accountId"]?.nilIfBlank,
            validatedAt: credential.metadata["lastValidatedAt"]?.nilIfBlank
                ?? credential.lastUsedAt?.nilIfBlank
        )
    }

    @discardableResult
    func normalizeAccountRegistryAgainstCredentials() -> Bool {
        let allCredentials = AccountCredentialStore.shared.loadAllCredentials()
        let credentialLookup = Dictionary(uniqueKeysWithValues: allCredentials.map { ($0.id, $0) })
        let credentialsByProvider = Dictionary(grouping: allCredentials, by: \.providerId)
        var didChange = false

        for index in accountRegistry.indices {
            var account = accountRegistry[index]
            var resolvedCredentialId = account.credentialId?.nilIfBlank

            if resolvedCredentialId == nil,
               let resultCredentialId = account.providerResultId.flatMap(extractCredentialId),
               let credential = credentialLookup[resultCredentialId],
               credential.providerId == account.providerId {
                resolvedCredentialId = credential.id
                account.credentialId = credential.id
                didChange = true
            }

            if resolvedCredentialId == nil,
               let matchedCredential = bestCredentialMatch(
                for: account,
                candidates: credentialsByProvider[account.providerId] ?? []
               ) {
                resolvedCredentialId = matchedCredential.id
                account.credentialId = matchedCredential.id
                didChange = true
            }

            guard let credentialId = resolvedCredentialId else { continue }
            guard let credential = credentialLookup[credentialId] else {
                accountRegistry[index] = account
                continue
            }

            guard credential.providerId == account.providerId else { continue }

            let accountHandle = credential.metadata["accountEmail"]?.nilIfBlank
                ?? credential.metadata["accountHandle"]?.nilIfBlank
                ?? credential.accountLabel?.nilIfBlank
            let displayName = credential.metadata["displayName"]?.nilIfBlank
            let accountId = credential.metadata["accountId"]?.nilIfBlank
            let validatedAt = credential.metadata["lastValidatedAt"]?.nilIfBlank
                ?? credential.lastUsedAt?.nilIfBlank
            let expectedResultId = "\(account.providerId):cred:\(credential.id)"

            if let accountHandle, account.email != accountHandle {
                account.email = accountHandle
                didChange = true
            }
            if let displayName, account.displayName != displayName {
                account.displayName = displayName
                didChange = true
            }
            if let accountId, account.accountId != accountId {
                account.accountId = accountId
                didChange = true
            }
            if account.providerResultId != expectedResultId {
                account.providerResultId = expectedResultId
                didChange = true
            }
            let normalizedSeenAt = maxTimestampString(account.lastSeenAt, validatedAt)
            if account.lastSeenAt != normalizedSeenAt {
                account.lastSeenAt = normalizedSeenAt
                didChange = true
            }

            accountRegistry[index] = account
        }

        return didChange
    }

    func bootstrapCredentialIndexFromRegistry() {
        let references = Set(
            accountRegistry.flatMap { account -> [AccountCredentialReference] in
                var refs: [AccountCredentialReference] = []
                if let credentialId = account.credentialId?.nilIfBlank {
                    refs.append(AccountCredentialReference(providerId: account.providerId, credentialId: credentialId))
                }
                if let providerResultCredentialId = account.providerResultId.flatMap(extractCredentialId) {
                    refs.append(AccountCredentialReference(providerId: account.providerId, credentialId: providerResultCredentialId))
                }
                return refs
            }
        )
        AccountCredentialStore.shared.bootstrapCredentialIndex(references: Array(references))
    }

    func deduplicateAccountRegistry() {
        let credentialLookup = Dictionary(
            uniqueKeysWithValues: AccountCredentialStore.shared.loadAllCredentials().map { ($0.id, $0) }
        )
        var seen: [String: Int] = [:]
        var indicesToRemove: [Int] = []

        for (index, account) in accountRegistry.enumerated() {
            let key = storedAccountIdentityKey(account)
            if let existingIndex = seen[key] {
                let existing = accountRegistry[existingIndex]
                let keepExisting = shouldPreferStoredAccount(existing, over: account, credentialLookup: credentialLookup)

                if keepExisting {
                    accountRegistry[existingIndex] = mergedStoredAccount(
                        preferred: existing,
                        secondary: account,
                        credentialLookup: credentialLookup
                    )
                    indicesToRemove.append(index)
                } else {
                    accountRegistry[index] = mergedStoredAccount(
                        preferred: account,
                        secondary: existing,
                        credentialLookup: credentialLookup
                    )
                    indicesToRemove.append(existingIndex)
                    seen[key] = index
                }
            } else {
                seen[key] = index
            }
        }

        if !indicesToRemove.isEmpty {
            for index in indicesToRemove.sorted(by: >) {
                accountRegistry.remove(at: index)
            }
        }
    }

    func storedAccountIdentityKey(_ account: StoredProviderAccount) -> String {
        let providerId = account.providerId.lowercased()
        if let accountId = account.normalizedAccountId {
            return "\(providerId):account:\(accountId)"
        }
        if !account.normalizedEmail.isEmpty {
            return "\(providerId):email:\(account.normalizedEmail)"
        }
        if let credentialId = account.credentialId?.lowercased().nilIfBlank {
            return "\(providerId):cred:\(credentialId)"
        }
        return "\(providerId):stored:\(account.id.lowercased())"
    }

    func shouldPreferStoredAccount(
        _ lhs: StoredProviderAccount,
        over rhs: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> Bool {
        if lhs.isHidden != rhs.isHidden {
            return !lhs.isHidden
        }

        let lhsHasCredential = lhs.credentialId.flatMap { credentialLookup[$0] } != nil
        let rhsHasCredential = rhs.credentialId.flatMap { credentialLookup[$0] } != nil
        if lhsHasCredential != rhsHasCredential {
            return lhsHasCredential
        }

        let lhsCredentialBound = extractCredentialId(from: lhs.providerResultId ?? "") != nil
        let rhsCredentialBound = extractCredentialId(from: rhs.providerResultId ?? "") != nil
        if lhsCredentialBound != rhsCredentialBound {
            return lhsCredentialBound
        }

        let lhsSeen = parseISO8601(lhs.lastSeenAt ?? "") ?? .distantPast
        let rhsSeen = parseISO8601(rhs.lastSeenAt ?? "") ?? .distantPast
        if lhsSeen != rhsSeen {
            return lhsSeen > rhsSeen
        }

        let lhsCreated = parseISO8601(lhs.createdAt) ?? .distantPast
        let rhsCreated = parseISO8601(rhs.createdAt) ?? .distantPast
        if lhsCreated != rhsCreated {
            return lhsCreated > rhsCreated
        }

        return lhs.id < rhs.id
    }

    func mergedStoredAccount(
        preferred: StoredProviderAccount,
        secondary: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> StoredProviderAccount {
        var merged = preferred

        if merged.displayName?.nilIfBlank == nil {
            merged.displayName = secondary.displayName?.nilIfBlank
        }
        if merged.note?.nilIfBlank == nil {
            merged.note = secondary.note?.nilIfBlank
        }
        if merged.accountId?.nilIfBlank == nil {
            merged.accountId = secondary.accountId?.nilIfBlank
        }
        if merged.credentialId?.nilIfBlank == nil,
           let fallbackCredentialId = secondary.credentialId?.nilIfBlank,
           credentialLookup[fallbackCredentialId] != nil {
            merged.credentialId = fallbackCredentialId
        }
        if merged.providerResultId?.nilIfBlank == nil {
            merged.providerResultId = secondary.providerResultId?.nilIfBlank
        }
        merged.lastSeenAt = maxTimestampString(preferred.lastSeenAt, secondary.lastSeenAt)
        merged.isHidden = preferred.isHidden && secondary.isHidden
        return merged
    }

    func maxTimestampString(_ values: String?...) -> String? {
        values
            .compactMap { $0?.nilIfBlank }
            .max {
                (parseISO8601($0) ?? .distantPast) < (parseISO8601($1) ?? .distantPast)
            }
    }

    func persistAccountRegistry() {
        try? SecureAccountVault.shared.saveAccounts(accountRegistry)
    }

    func cleanupManagedCredentialArtifacts() {
        let credentials = AccountCredentialStore.shared.loadAllCredentials()
        guard !credentials.isEmpty else { return }
        ProviderManagedImportStore.cleanupOrphanedManagedImports(referencedBy: credentials)
    }
}
