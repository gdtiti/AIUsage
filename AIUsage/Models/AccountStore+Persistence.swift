import Foundation
import Combine
import QuotaBackend
import os.log

internal let accountPersistenceLog = Logger(subsystem: "com.aiusage.desktop", category: "AccountPersistence")

struct AccountRegistryReconcileResult: Sendable {
    let accounts: [StoredProviderAccount]
    let didChange: Bool
}

actor AccountRegistryRefreshWorker {
    static let shared = AccountRegistryRefreshWorker()

    private var latestRequestedRevision: UInt64 = 0
    private var lastPersistedRevision: UInt64 = 0
    private var lastPersistedAccounts: [StoredProviderAccount]?

    func reconcile(
        currentRegistry: [StoredProviderAccount],
        providers: [ProviderData],
        providerCatalogOrder: [String]
    ) -> AccountRegistryReconcileResult {
        let allCredentials = AccountCredentialStore.shared.loadAllCredentials()
        var snapshot = AccountRegistryRefreshSnapshot(
            accountRegistry: currentRegistry,
            providerCatalogOrder: providerCatalogOrder,
            allCredentials: allCredentials
        )
        let didChange = snapshot.reconcile(with: providers)
        return AccountRegistryReconcileResult(accounts: snapshot.accountRegistry, didChange: didChange)
    }

    func schedulePersist(_ accounts: [StoredProviderAccount], revision: UInt64) async {
        latestRequestedRevision = max(latestRequestedRevision, revision)

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard revision == latestRequestedRevision else { return }
        guard revision > lastPersistedRevision else { return }
        guard lastPersistedAccounts != accounts else { return }

        do {
            try SecureAccountVault.shared.saveAccounts(accounts)
            lastPersistedRevision = revision
            lastPersistedAccounts = accounts
        } catch {
            Logger(subsystem: "com.aiusage.desktop", category: "AccountPersistence").error(
                "Failed to persist account registry from background refresh worker (state kept in memory): \(String(describing: error), privacy: .public)"
            )
        }
    }

    func notePersistedSnapshot(_ accounts: [StoredProviderAccount], revision: UInt64) {
        latestRequestedRevision = max(latestRequestedRevision, revision)
        if revision >= lastPersistedRevision {
            lastPersistedRevision = revision
            lastPersistedAccounts = accounts
        }
    }
}

private struct AccountRegistryRefreshSnapshot {
    var accountRegistry: [StoredProviderAccount]
    let providerCatalogOrder: [String]
    let credentialLookup: [String: AccountCredential]
    let credentialsByProvider: [String: [AccountCredential]]

    nonisolated init(
        accountRegistry: [StoredProviderAccount],
        providerCatalogOrder: [String],
        allCredentials: [AccountCredential]
    ) {
        self.accountRegistry = accountRegistry
        self.providerCatalogOrder = providerCatalogOrder
        self.credentialLookup = Dictionary(uniqueKeysWithValues: allCredentials.map { ($0.id, $0) })
        self.credentialsByProvider = Dictionary(grouping: allCredentials, by: \.providerId)
    }

    nonisolated mutating func reconcile(with providers: [ProviderData]) -> Bool {
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

        return didChange
    }

    nonisolated func normalizedAccountLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    nonisolated func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    nonisolated func bestCredentialMatch(
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
               normalizedAccountLookupValue(
                   $0.metadata["accountEmail"]
                       ?? $0.metadata["accountHandle"]
                       ?? $0.accountLabel
               ) == account.normalizedEmail
           }) {
            return emailMatch
        }

        return nil
    }

    nonisolated func bestStoredAccountIndex(
        for provider: ProviderData,
        excluding reservedStoredIDs: Set<String>,
        allowUnseenCredentialFallback: Bool
    ) -> Int? {
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

    nonisolated func storedAccountMatchesLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
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
           let liveAccountId = provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank,
           storedAccountId == liveAccountId {
            return true
        }

        if let liveEmail = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank,
           stored.normalizedEmail == liveEmail {
            return true
        }

        return false
    }

    nonisolated func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let lhsProviderIndex = providerCatalogOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsProviderIndex = providerCatalogOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsProviderIndex != rhsProviderIndex {
            return lhsProviderIndex < rhsProviderIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }

    nonisolated mutating func deduplicateAccountRegistry() {
        var seen: [String: Int] = [:]
        var indicesToRemove: [Int] = []

        for (index, account) in accountRegistry.enumerated() {
            let key = storedAccountIdentityKey(account)
            if let existingIndex = seen[key] {
                let existing = accountRegistry[existingIndex]
                let keepExisting = shouldPreferStoredAccount(existing, over: account)

                if keepExisting {
                    accountRegistry[existingIndex] = mergedStoredAccount(preferred: existing, secondary: account)
                    indicesToRemove.append(index)
                } else {
                    accountRegistry[index] = mergedStoredAccount(preferred: account, secondary: existing)
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

    nonisolated func storedAccountIdentityKey(_ account: StoredProviderAccount) -> String {
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

    nonisolated func shouldPreferStoredAccount(
        _ lhs: StoredProviderAccount,
        over rhs: StoredProviderAccount
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

        let lhsSeen = SharedFormatters.parseISO8601(lhs.lastSeenAt ?? "") ?? .distantPast
        let rhsSeen = SharedFormatters.parseISO8601(rhs.lastSeenAt ?? "") ?? .distantPast
        if lhsSeen != rhsSeen {
            return lhsSeen > rhsSeen
        }

        let lhsCreated = SharedFormatters.parseISO8601(lhs.createdAt) ?? .distantPast
        let rhsCreated = SharedFormatters.parseISO8601(rhs.createdAt) ?? .distantPast
        if lhsCreated != rhsCreated {
            return lhsCreated > rhsCreated
        }

        return lhs.id < rhs.id
    }

    nonisolated func mergedStoredAccount(
        preferred: StoredProviderAccount,
        secondary: StoredProviderAccount
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

    nonisolated func maxTimestampString(_ values: String?...) -> String? {
        values
            .compactMap { $0?.nilIfBlank }
            .max {
                (SharedFormatters.parseISO8601($0) ?? .distantPast)
                    < (SharedFormatters.parseISO8601($1) ?? .distantPast)
            }
    }
}

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

    @discardableResult
    func persistAccountRegistry() -> Bool {
        let snapshot = accountRegistry
        let revision = accountRegistryRevision
        do {
            try SecureAccountVault.shared.saveAccounts(snapshot)
            Task.detached(priority: .utility) {
                await AccountRegistryRefreshWorker.shared.notePersistedSnapshot(snapshot, revision: revision)
            }
            return true
        } catch {
            accountPersistenceLog.error("Failed to persist account registry (state kept in memory): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func cleanupManagedCredentialArtifacts() {
        let credentials = AccountCredentialStore.shared.loadAllCredentials()
        guard !credentials.isEmpty else { return }
        ProviderManagedImportStore.cleanupOrphanedManagedImports(referencedBy: credentials)
    }
}
