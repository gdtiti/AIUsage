import Foundation
import Combine
import QuotaBackend

// MARK: - AccountStore
// Persists multi-provider account registry (SecureAccountVault), normalizes against
// AccountCredentialStore, deduplicates, and reconciles with live ProviderData snapshots.

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var accountRegistry: [StoredProviderAccount] = []

    /// Base provider ids in UI/catalog order; must match `AppState.providerCatalogItems`.
    var providerCatalogOrder: [String] = []

    private init() {
        accountRegistry = SecureAccountVault.shared.loadAccounts()
    }

    /// Call once at app launch after `AppState` can supply catalog order (before refresh).
    func bootstrapFromDisk(providerCatalogOrder: [String]) {
        self.providerCatalogOrder = providerCatalogOrder
        bootstrapCredentialIndexFromRegistry()
        normalizePersistedState()
        cleanupManagedCredentialArtifacts()
    }

    func updateProviderCatalogOrder(_ ids: [String]) {
        providerCatalogOrder = ids
    }

    // MARK: - Public account API

    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil,
        ensureProviderSelected: (String) -> Void
    ) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return }

        let now = SharedFormatters.iso8601String(from: Date())
        let credentialSnapshot = credentialId.flatMap {
            credentialAccountSnapshot(providerId: providerId, credentialId: $0)
        }
        let effectiveEmail = credentialSnapshot?.accountHandle ?? normalizedEmail
        let normalizedLookup = effectiveEmail.lowercased()
        let normalizedAccountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialSnapshot?.normalizedAccountId
        let normalizedProviderResultId = providerResultId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialId.map { "\(providerId):cred:\($0)".lowercased() }
        let effectiveDisplayName = displayName?.nilIfBlank ?? credentialSnapshot?.displayName

        if let index = accountRegistry.firstIndex(where: {
            guard $0.providerId == providerId else { return false }
            if let credentialId, $0.credentialId == credentialId { return true }
            if let normalizedProviderResultId, $0.normalizedProviderResultId == normalizedProviderResultId { return true }
            if let normalizedAccountId, $0.normalizedAccountId == normalizedAccountId { return true }
            return $0.normalizedEmail == normalizedLookup
        }) {
            let existing = accountRegistry[index]
            accountRegistry[index] = StoredProviderAccount(
                id: existing.id,
                providerId: existing.providerId,
                email: effectiveEmail,
                displayName: effectiveDisplayName ?? existing.displayName,
                note: note?.nilIfBlank ?? existing.note,
                accountId: normalizedAccountId ?? existing.accountId,
                providerResultId: normalizedProviderResultId ?? existing.providerResultId,
                credentialId: credentialId ?? existing.credentialId,
                createdAt: existing.createdAt,
                lastSeenAt: maxTimestampString(now, existing.lastSeenAt, credentialSnapshot?.validatedAt),
                isHidden: false
            )
        } else {
            accountRegistry.append(
                StoredProviderAccount(
                    id: UUID().uuidString,
                    providerId: providerId,
                    email: effectiveEmail,
                    displayName: effectiveDisplayName,
                    note: note?.nilIfBlank,
                    accountId: normalizedAccountId,
                    providerResultId: normalizedProviderResultId,
                    credentialId: credentialId,
                    createdAt: now,
                    lastSeenAt: maxTimestampString(now, credentialSnapshot?.validatedAt),
                    isHidden: false
                )
            )
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        ensureProviderSelected(providerId)
        persistAccountRegistry()
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String,
        insertImmediateProviderData: (_ providerId: String, _ credentialId: String, _ accountLabel: String?, _ usage: ProviderUsage) -> Void,
        ensureProviderSelected: (String) -> Void
    ) throws {
        let providerId = credential.providerId
        let accountHandle: String = {
            if let v = usage.accountEmail?.nilIfBlank { return v }
            if let v = usage.accountLogin?.nilIfBlank { return v }
            if let v = usage.accountName?.nilIfBlank { return v }
            if let v = credential.accountLabel?.nilIfBlank { return v }
            if let v = usage.usageAccountId?.nilIfBlank { return v }
            return "\(providerDisplayTitle) Account"
        }()
        let displayName: String? = usage.accountName?.nilIfBlank
            ?? credential.accountLabel?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank
        let accountId: String? = usage.usageAccountId?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank

        var enrichedCredential = credential
        let validatedAt = SharedFormatters.iso8601String(from: Date())
        enrichedCredential.metadata["accountHandle"] = accountHandle
        enrichedCredential.metadata["lastValidatedAt"] = validatedAt
        if let accountEmail = usage.accountEmail?.nilIfBlank {
            enrichedCredential.metadata["accountEmail"] = accountEmail
        }
        if let displayName {
            enrichedCredential.metadata["displayName"] = displayName
        }
        if let accountId {
            enrichedCredential.metadata["accountId"] = accountId
        }
        enrichedCredential.lastUsedAt = validatedAt

        if let existingCredential = existingAuthenticatedCredential(
            providerId: providerId,
            accountHandle: accountHandle,
            accountId: accountId,
            sessionFingerprint: enrichedCredential.metadata["sessionFingerprint"],
            sourceIdentifier: enrichedCredential.metadata["sourceIdentifier"],
            sourceIdentifierIsStable: enrichedCredential.metadata["identityScope"]
                == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue
        ) {
            var mergedMetadata = existingCredential.metadata
            enrichedCredential.metadata.forEach { mergedMetadata[$0.key] = $0.value }
            enrichedCredential = AccountCredential(
                id: existingCredential.id,
                providerId: existingCredential.providerId,
                accountLabel: enrichedCredential.accountLabel ?? existingCredential.accountLabel,
                authMethod: enrichedCredential.authMethod,
                credential: enrichedCredential.credential,
                metadata: mergedMetadata
            )
            enrichedCredential.lastUsedAt = validatedAt
            ProviderManagedImportStore.reuseManagedImportIfPossible(
                existingCredential: existingCredential,
                incomingCredential: &enrichedCredential
            )
        }

        try AccountCredentialStore.shared.saveCredential(enrichedCredential)
        let credentialRemapping = AccountCredentialStore.shared.deduplicateCredentials(for: providerId)
        if !credentialRemapping.isEmpty {
            applyCredentialRemapping(credentialRemapping)
            if let remappedID = credentialRemapping[enrichedCredential.id] {
                let canonicalCredential = AccountCredentialStore.shared
                    .loadCredentials(for: providerId)
                    .first(where: { $0.id == remappedID })
                var rewrittenCanonicalCredential = AccountCredential(
                    id: remappedID,
                    providerId: enrichedCredential.providerId,
                    accountLabel: enrichedCredential.accountLabel,
                    authMethod: enrichedCredential.authMethod,
                    credential: enrichedCredential.credential,
                    metadata: enrichedCredential.metadata
                )
                rewrittenCanonicalCredential.lastUsedAt = validatedAt
                if let canonicalCredential {
                    ProviderManagedImportStore.reuseManagedImportIfPossible(
                        existingCredential: canonicalCredential,
                        incomingCredential: &rewrittenCanonicalCredential
                    )
                }
                try AccountCredentialStore.shared.saveCredential(rewrittenCanonicalCredential)
                enrichedCredential = rewrittenCanonicalCredential
            }
        }

        saveAccount(
            providerId: providerId,
            email: accountHandle,
            displayName: displayName,
            note: note,
            accountId: accountId,
            credentialId: enrichedCredential.id,
            providerResultId: "\(providerId):cred:\(enrichedCredential.id)",
            ensureProviderSelected: ensureProviderSelected
        )

        insertImmediateProviderData(
            providerId,
            enrichedCredential.id,
            enrichedCredential.accountLabel ?? accountHandle,
            usage
        )
    }

    func updateAccountNote(
        for entry: ProviderAccountEntry,
        note: String?,
        onProviderActivated: (String) -> Void
    ) {
        let now = SharedFormatters.iso8601String(from: Date())

        if let index = bestStoredAccountIndex(for: entry) {
            accountRegistry[index].note = note?.nilIfBlank
            accountRegistry[index].isHidden = false
            accountRegistry[index].providerResultId = entry.liveProvider?.id ?? accountRegistry[index].providerResultId
            accountRegistry[index].accountId = entry.liveProvider?.accountId ?? accountRegistry[index].accountId
            accountRegistry[index].lastSeenAt = entry.liveProvider == nil ? accountRegistry[index].lastSeenAt : now
        } else if let created = makeStoredAccount(
            from: entry,
            note: note?.nilIfBlank,
            isHidden: false,
            lastSeenAt: entry.liveProvider == nil ? nil : now
        ) {
            accountRegistry.append(created)
        } else {
            return
        }

        onProviderActivated(entry.providerId)
        persistAccountRegistry()
    }

    func restoreAccount(_ storedAccountId: String, onRestored: (String) -> Void) {
        guard let index = accountRegistry.firstIndex(where: { $0.id == storedAccountId }) else { return }
        accountRegistry[index].isHidden = false
        persistAccountRegistry()
        onRestored(accountRegistry[index].providerId)
    }

    func deleteAccount(
        _ entry: ProviderAccountEntry,
        onPostRegistryDelete: () -> Void
    ) {
        let matchedCredentials = matchingCredentialsImpl(for: entry)
        for credential in matchedCredentials {
            AccountCredentialStore.shared.deleteCredential(credential)
        }

        let matchingIndices = matchingStoredAccountIndices(for: entry)
        if !matchingIndices.isEmpty {
            for index in matchingIndices {
                var updated = accountRegistry[index]
                updated.note = nil
                updated.credentialId = nil
                updated.providerResultId = entry.liveProvider?.id ?? updated.providerResultId
                updated.accountId = entry.liveProvider?.accountId ?? updated.accountId
                updated.isHidden = true
                updated.lastSeenAt = maxTimestampString(
                    SharedFormatters.iso8601String(from: Date()),
                    updated.lastSeenAt
                )
                accountRegistry[index] = updated
            }
        } else if let hiddenEntry = makeStoredAccount(
            from: entry,
            note: nil,
            isHidden: true,
            lastSeenAt: SharedFormatters.iso8601String(from: Date())
        ) {
            accountRegistry.append(hiddenEntry)
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()

        onPostRegistryDelete()

        cleanupManagedCredentialArtifacts()
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountRegistry.first(where: { !$0.isHidden && storedAccountMatchesLive($0, provider: provider) })?.note?.nilIfBlank
    }

    /// Credentials that plausibly belong to this account entry (used for CLI path resolution, etc.).
    func matchingCredentials(for entry: ProviderAccountEntry) -> [AccountCredential] {
        matchingCredentialsImpl(for: entry)
    }

    func hiddenAccounts() -> [StoredProviderAccount] {
        let providerOrder = providerCatalogOrder
        return accountRegistry
            .filter(\.isHidden)
            .sorted {
                if $0.providerId != $1.providerId {
                    let lhsIndex = providerOrder.firstIndex(of: $0.providerId) ?? Int.max
                    let rhsIndex = providerOrder.firstIndex(of: $1.providerId) ?? Int.max
                    return lhsIndex < rhsIndex
                }
                return $0.preferredLabel.localizedCaseInsensitiveCompare($1.preferredLabel) == .orderedAscending
            }
    }

    func reconcileAccountRegistry(with providers: [ProviderData]) {
        var didChange = false
        let now = SharedFormatters.iso8601String(from: Date())
        var reservedStoredIDs = Set<String>()
        let allowUnseenCredentialFallback = providers.count == 1
        let orderedProviders = providers.sorted { lhs, rhs in
            let lhsCredentialBacked = extractCredentialId(from: lhs.id) != nil
            let rhsCredentialBacked = extractCredentialId(from: rhs.id) != nil
            if lhsCredentialBacked != rhsCredentialBacked {
                return lhsCredentialBacked && !rhsCredentialBacked
            }
            return providerSort(lhs, rhs)
        }

        for provider in orderedProviders {
            let label = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? provider.label.nilIfBlank

            guard let label else {
                continue
            }

            let inferredCredentialId = extractCredentialId(from: provider.id)

            if let hiddenIndex = accountRegistry.firstIndex(where: {
                !$0.id.isEmpty && !reservedStoredIDs.contains($0.id) && $0.isHidden && storedAccountMatchesLive($0, provider: provider)
            }) {
                var hidden = accountRegistry[hiddenIndex]
                if hidden.providerResultId != provider.id {
                    hidden.providerResultId = provider.id
                    didChange = true
                }
                if hidden.accountId != provider.accountId {
                    hidden.accountId = provider.accountId
                    didChange = true
                }
                if hidden.credentialId == nil, let inferredCredentialId {
                    hidden.credentialId = inferredCredentialId
                    didChange = true
                }
                if hidden.lastSeenAt != now {
                    hidden.lastSeenAt = now
                    didChange = true
                }
                accountRegistry[hiddenIndex] = hidden
                reservedStoredIDs.insert(hidden.id)
                continue
            }

            if let index = bestStoredAccountIndex(
                for: provider,
                excluding: reservedStoredIDs,
                allowUnseenCredentialFallback: allowUnseenCredentialFallback
            ) {
                var updated = accountRegistry[index]
                if updated.email != label {
                    updated.email = label
                    didChange = true
                }
                if updated.accountId != provider.accountId {
                    updated.accountId = provider.accountId
                    didChange = true
                }
                if updated.providerResultId != provider.id {
                    updated.providerResultId = provider.id
                    didChange = true
                }
                if updated.credentialId == nil, let inferredCredentialId {
                    updated.credentialId = inferredCredentialId
                    didChange = true
                }
                if updated.lastSeenAt != now {
                    updated.lastSeenAt = now
                    didChange = true
                }
                if updated.isHidden {
                    updated.isHidden = false
                    didChange = true
                }
                accountRegistry[index] = updated
                reservedStoredIDs.insert(updated.id)
            } else {
                let normalizedNewEmail = label.lowercased()
                let normalizedNewAccountId = provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
                if let dupeIndex = accountRegistry.firstIndex(where: {
                    $0.providerId == provider.baseProviderId && !$0.isHidden && (
                        $0.normalizedEmail == normalizedNewEmail ||
                        (normalizedNewAccountId != nil && $0.normalizedAccountId == normalizedNewAccountId)
                    )
                }) {
                    var existing = accountRegistry[dupeIndex]
                    if existing.providerResultId != provider.id {
                        existing.providerResultId = provider.id
                        didChange = true
                    }
                    if existing.accountId != provider.accountId {
                        existing.accountId = provider.accountId
                        didChange = true
                    }
                    if existing.credentialId == nil, let inferredCredentialId {
                        existing.credentialId = inferredCredentialId
                        didChange = true
                    }
                    if existing.lastSeenAt != now {
                        existing.lastSeenAt = now
                        didChange = true
                    }
                    accountRegistry[dupeIndex] = existing
                    reservedStoredIDs.insert(existing.id)
                } else {
                    let stored = StoredProviderAccount(
                        id: UUID().uuidString,
                        providerId: provider.baseProviderId,
                        email: label,
                        displayName: nil,
                        note: nil,
                        accountId: provider.accountId,
                        providerResultId: provider.id,
                        credentialId: inferredCredentialId,
                        createdAt: now,
                        lastSeenAt: now,
                        isHidden: false
                    )
                    accountRegistry.append(stored)
                    reservedStoredIDs.insert(stored.id)
                    didChange = true
                }
            }
        }

        let beforeDedup = accountRegistry.count
        deduplicateAccountRegistry()
        if accountRegistry.count != beforeDedup {
            didChange = true
        }

        if didChange {
            persistAccountRegistry()
        }
    }

    func hasHiddenRegistryMatch(providerId: String, normalizedEmail: String?, normalizedAccountId: String?) -> Bool {
        accountRegistry.contains { stored in
            guard stored.providerId == providerId, stored.isHidden else { return false }
            if let normalizedAccountId,
               stored.normalizedAccountId == normalizedAccountId {
                return true
            }
            if let normalizedEmail,
               stored.normalizedEmail == normalizedEmail {
                return true
            }
            return false
        }
    }

    /// Whether `stored` refers to the same logical account as live `provider` data.
    func matchesStoredWithLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        storedAccountMatchesLive(stored, provider: provider)
    }
}
