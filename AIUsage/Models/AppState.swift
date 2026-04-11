import SwiftUI
import Combine
import QuotaBackend

enum CardQuotaIndicatorStyle: String, CaseIterable {
    case bar
    case ring
    case segments
}

enum CardQuotaIndicatorMetric: String, CaseIterable {
    case remaining
    case used
}

enum AppSection: String, Hashable {
    case dashboard
    case providers
    case costTracking
    case inbox
    case settings
}

// 全局应用状态
class AppState: ObservableObject {
    static let shared = AppState()
    private static let selectedProvidersKey = "selectedProviderIds"
    static let supportedAutoRefreshIntervals: [Int] = [30, 60, 180, 300, 600, 900, 1800, 3600, 0]
    static let defaultAutoRefreshInterval = 300
    private struct InitialState {
        let accounts: [StoredProviderAccount]
        let selectedProviderIds: Set<String>
    }

    private static let providerCatalogItems: [ProviderCatalogItem] = [
        ProviderCatalogItem(id: "codex", titleEn: "Codex", titleZh: "Codex", summaryEn: "Official OpenAI subscription windows and quotas", summaryZh: "OpenAI 官方订阅窗口与配额", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "copilot", titleEn: "Copilot", titleZh: "Copilot", summaryEn: "GitHub Copilot account entitlements and premium lanes", summaryZh: "GitHub Copilot 账号权益与高级通道", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "cursor", titleEn: "Cursor", titleZh: "Cursor", summaryEn: "Cursor membership allowances and plan usage", summaryZh: "Cursor 会员额度与计划用量", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "antigravity", titleEn: "Antigravity", titleZh: "Antigravity", summaryEn: "Per-model IDE subscription quotas across many model families", summaryZh: "按模型拆分的 IDE 订阅配额", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "kiro", titleEn: "Kiro", titleZh: "Kiro", summaryEn: "Kiro IDE request lanes from the live app account", summaryZh: "来自 Kiro 应用账号的实时请求通道", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "warp", titleEn: "Warp", titleZh: "Warp", summaryEn: "Warp request reserves and desktop app credits", summaryZh: "Warp 请求余额与桌面应用额度", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "gemini", titleEn: "Gemini CLI", titleZh: "Gemini CLI", summaryEn: "Gemini CLI project quotas and model-family windows", summaryZh: "Gemini CLI 项目配额与模型族窗口", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "amp", titleEn: "Amp", titleZh: "Amp", summaryEn: "Replenishing credit pool and refill cadence", summaryZh: "会回补的额度池与回补节奏", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "droid", titleEn: "Droid", titleZh: "Droid", summaryEn: "Token-heavy usage pools and remaining allowances", summaryZh: "以 token 为主的额度池与剩余额度", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "claude", titleEn: "Claude Code Spend", titleZh: "Claude Code 费用", summaryEn: "Local log-based spend ledger from Claude Code usage", summaryZh: "基于 Claude Code 本地日志的费用账本", channel: "local", kind: .costTracking)
    ]

    private static let initialState: InitialState = {
        let accounts = SecureAccountVault.shared.loadAccounts()
        let saved = Set(UserDefaults.standard.stringArray(forKey: selectedProvidersKey) ?? [])
        let storedProviderIDs = accounts.filter { !$0.isHidden }.map(\.providerId)
        let validIDs = Set(providerCatalogItems.map(\.id))
        let merged = Set(saved.union(storedProviderIDs).filter { validIDs.contains($0) })
        return InitialState(accounts: accounts, selectedProviderIds: merged)
    }()
    
    @Published var providers: [ProviderData] = []
    @Published var overview: DashboardOverview?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var lastRefreshTime: Date?
    @Published var isRefreshingAllProviders = false
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var refreshingAccountIDs: Set<String> = []
    @Published private(set) var providerRefreshTimes: [String: Date] = [:]
    @Published private(set) var accountRefreshTimes: [String: Date] = [:]
    @Published var accountRegistry: [StoredProviderAccount] = AppState.initialState.accounts
    
    // UI 状态
    @Published var isDarkMode = UserDefaults.standard.bool(forKey: "isDarkMode")
    @Published var showSettings = false
    @Published var selectedProviderId: String?
    @Published var selectedSection: AppSection = .dashboard
    @Published var providerPickerMode: ProviderPickerMode?
    @Published var selectedProviderIds: Set<String> = AppState.initialState.selectedProviderIds
    @Published var autoRefreshInterval: Int = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: "autoRefreshInterval") != nil
            ? defaults.integer(forKey: "autoRefreshInterval")
            : AppState.defaultAutoRefreshInterval
        return AppState.normalizedAutoRefreshInterval(storedValue)
    }()
    @Published var language: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
    @Published var quotaIndicatorStyle: CardQuotaIndicatorStyle = CardQuotaIndicatorStyle(rawValue: UserDefaults.standard.string(forKey: "quotaIndicatorStyle") ?? "") ?? .bar
    @Published var quotaIndicatorMetric: CardQuotaIndicatorMetric = CardQuotaIndicatorMetric(rawValue: UserDefaults.standard.string(forKey: "quotaIndicatorMetric") ?? "") ?? .remaining

    // Backend mode: "local" (直接调用 Swift Provider) 或 "remote" (通过 HTTP)
    @Published var backendMode: String = UserDefaults.standard.string(forKey: "backendMode") ?? "local"
    @Published var remoteHost: String = UserDefaults.standard.string(forKey: "remoteHost") ?? "127.0.0.1"
    @Published var remotePort: Int = UserDefaults.standard.integer(forKey: "remotePort") == 0 ? 4318 : UserDefaults.standard.integer(forKey: "remotePort")

    // Local mode engine
    private let engine = ProviderEngine()

    @Published var readAlertIds: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: "readAlertIds") ?? []
        return Set(arr)
    }()

    var unreadAlertCount: Int {
        let alerts = overview?.alerts ?? []
        return alerts.filter { !readAlertIds.contains($0.id) }.count
    }

    func markAlertRead(_ id: String) {
        readAlertIds.insert(id)
        UserDefaults.standard.set(Array(readAlertIds), forKey: "readAlertIds")
    }

    func markAllAlertsRead() {
        let ids = (overview?.alerts ?? []).map { $0.id }
        readAlertIds.formUnion(ids)
        UserDefaults.standard.set(Array(readAlertIds), forKey: "readAlertIds")
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var didRunStartupFlow = false
    private var discoveryFailureBackoff: [String: Date] = [:]
    private let discoveryFailureCooldown: TimeInterval = 5 * 60
    
    private init() {
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        bootstrapCredentialIndexFromRegistry()
        normalizePersistedState()
        setupAutoRefresh()
        detectActiveCodexAccount()
        detectActiveGeminiAccount()
    }

    static func normalizedAutoRefreshInterval(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        guard !supportedAutoRefreshIntervals.contains(value) else { return value }

        return supportedAutoRefreshIntervals
            .filter { $0 > 0 }
            .min(by: { abs($0 - value) < abs($1 - value) })
            ?? defaultAutoRefreshInterval
    }

    @MainActor
    func performStartupFlowIfNeeded() async {
        guard !didRunStartupFlow else { return }
        didRunStartupFlow = true

        guard needsInitialProviderSetup else { return }
        await Task.yield()
        providerPickerMode = .initialSetup
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        defaults.set(autoRefreshInterval, forKey: "autoRefreshInterval")
        defaults.set(isDarkMode, forKey: "isDarkMode")
        defaults.set(language, forKey: "appLanguage")
        defaults.set(quotaIndicatorStyle.rawValue, forKey: "quotaIndicatorStyle")
        defaults.set(quotaIndicatorMetric.rawValue, forKey: "quotaIndicatorMetric")
        defaults.set(backendMode, forKey: "backendMode")
        defaults.set(remoteHost, forKey: "remoteHost")
        defaults.set(remotePort, forKey: "remotePort")
        APIService.shared.updateBaseURL("http://\(remoteHost):\(remotePort)")
    }
    
    func t(_ en: String, _ zh: String) -> String {
        language == "zh" ? zh : en
    }

    var providerCatalog: [ProviderCatalogItem] {
        Self.providerCatalogItems
    }

    func providerCatalogItem(for id: String) -> ProviderCatalogItem? {
        providerCatalog.first { $0.id == id }
    }

    var unselectedProviderCatalog: [ProviderCatalogItem] {
        providerCatalog.filter { !selectedProviderIds.contains($0.id) }
    }

    var needsInitialProviderSetup: Bool {
        selectedProviderIds.isEmpty && accountRegistry.isEmpty
    }

    func presentAddProviderPicker() {
        guard !unselectedProviderCatalog.isEmpty else { return }
        providerPickerMode = .add
    }

    func presentManageProviderPicker() {
        providerPickerMode = .manage
    }

    func dismissProviderPicker() {
        providerPickerMode = nil
    }

    func completeInitialProviderSetup(with ids: Set<String>) {
        selectedProviderIds = sanitizedProviderIDs(ids)
        saveSelectedProviderIds()
        providerPickerMode = nil
        refreshAllProviders()
    }

    func addProviders(_ ids: Set<String>) {
        guard !ids.isEmpty else {
            providerPickerMode = nil
            return
        }
        selectedProviderIds.formUnion(sanitizedProviderIDs(ids))
        saveSelectedProviderIds()
        providerPickerMode = nil
        refreshAllProviders()
    }

    func updateProviderSelection(with ids: Set<String>) {
        let sanitized = sanitizedProviderIDs(ids)
        let removed = selectedProviderIds.subtracting(sanitized)

        selectedProviderIds = sanitized
        saveSelectedProviderIds()
        providerPickerMode = nil

        if !removed.isEmpty {
            providers.removeAll { removed.contains($0.baseProviderId) }
        }

        refreshAllProviders()
    }

    func setProviderScanningEnabled(_ providerId: String, isEnabled: Bool) {
        guard providerCatalog.contains(where: { $0.id == providerId }) else { return }

        if isEnabled {
            guard !selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.insert(providerId)
        } else {
            guard selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.remove(providerId)
            providers.removeAll { $0.baseProviderId == providerId }
        }

        saveSelectedProviderIds()
        refreshAllProviders()
    }

    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil
    ) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return }

        let now = ISO8601DateFormatter().string(from: Date())
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
        selectedProviderIds.insert(providerId)
        saveSelectedProviderIds()
        persistAccountRegistry()
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String? = nil
    ) throws {
        let providerId = credential.providerId
        let providerTitle = providerCatalogItem(for: providerId)?.title(for: language) ?? providerId
        let accountHandle: String = {
            if let v = usage.accountEmail?.nilIfBlank { return v }
            if let v = usage.accountLogin?.nilIfBlank { return v }
            if let v = usage.accountName?.nilIfBlank { return v }
            if let v = credential.accountLabel?.nilIfBlank { return v }
            if let v = usage.usageAccountId?.nilIfBlank { return v }
            return "\(providerTitle) Account"
        }()
        let displayName: String? = usage.accountName?.nilIfBlank
            ?? credential.accountLabel?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank
        let accountId: String? = usage.usageAccountId?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank

        var enrichedCredential = credential
        let validatedAt = ISO8601DateFormatter().string(from: Date())
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
            providerResultId: "\(providerId):cred:\(enrichedCredential.id)"
        )

        insertImmediateProviderData(
            providerId: providerId,
            credentialId: enrichedCredential.id,
            accountLabel: enrichedCredential.accountLabel ?? accountHandle,
            usage: usage
        )
    }

    private func insertImmediateProviderData(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        usage: ProviderUsage
    ) {
        guard let providerFetcher = ProviderRegistry.provider(for: providerId) else { return }

        var summary = UsageNormalizer.normalize(provider: providerFetcher, usage: usage)
        summary.id = "\(providerId):cred:\(credentialId)"
        summary.providerId = providerId
        summary.accountId = usage.usageAccountId
        if summary.accountLabel?.nilIfBlank == nil {
            summary.accountLabel = accountLabel
        }

        let providerData = localizeProviderData(convertSummary(summary))

        if let index = providers.firstIndex(where: { $0.id == providerData.id }) {
            providers[index] = providerData
        } else {
            providers.append(providerData)
            providers = providers.sorted(by: providerSort)
        }
    }

    private func existingAuthenticatedCredential(
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

    private func normalizePersistedState() {
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
    private func applyCredentialRemapping(_ remappedCredentialIDs: [String: String]) -> Bool {
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

    private func normalizedAccountLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func updateAccountNote(for entry: ProviderAccountEntry, note: String?) {
        let now = ISO8601DateFormatter().string(from: Date())

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

        if selectedProviderIds.insert(entry.providerId).inserted {
            saveSelectedProviderIds()
        }
        persistAccountRegistry()
    }

    func restoreAccount(_ storedAccountId: String) {
        guard let index = accountRegistry.firstIndex(where: { $0.id == storedAccountId }) else { return }
        accountRegistry[index].isHidden = false
        selectedProviderIds.insert(accountRegistry[index].providerId)
        saveSelectedProviderIds()
        persistAccountRegistry()
        refreshProvider(accountRegistry[index].providerId)
    }

    func deleteAccount(_ entry: ProviderAccountEntry) {
        let matchedCredentials = matchingCredentials(for: entry)
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
                    ISO8601DateFormatter().string(from: Date()),
                    updated.lastSeenAt
                )
                accountRegistry[index] = updated
            }
        } else if let hiddenEntry = makeStoredAccount(
            from: entry,
            note: nil,
            isHidden: true,
            lastSeenAt: ISO8601DateFormatter().string(from: Date())
        ) {
            accountRegistry.append(hiddenEntry)
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()
        providers = visibleProviders(from: providers).sorted(by: providerSort)

        cleanupManagedCredentialArtifacts()
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountRegistry.first(where: { !$0.isHidden && storedAccountMatchesLive($0, provider: provider) })?.note?.nilIfBlank
    }

    var providerAccountGroups: [ProviderAccountGroup] {
        // Group live providers by base providerId (handles multi-account: "antigravity:a@b.com" → "antigravity")
        let liveProvidersById = Dictionary(grouping: providers, by: \.baseProviderId)

        return providerCatalog
            .filter { item in
                selectedProviderIds.contains(item.id)
                    || accountRegistry.contains(where: { $0.providerId == item.id && !$0.isHidden })
                    || !(liveProvidersById[item.id] ?? []).isEmpty
            }
            .compactMap { item in
                let liveProviders = liveProvidersById[item.id] ?? []
                let storedAccounts = accountRegistry.filter { $0.providerId == item.id && !$0.isHidden }
                let entries = buildProviderEntries(
                    providerId: item.id,
                    providerTitle: item.title(for: language),
                    providerSubtitle: item.summary(for: language),
                    liveProviders: liveProviders,
                    storedAccounts: storedAccounts
                )

                let sortedEntries = entries.sorted { lhs, rhs in
                    if lhs.isConnected != rhs.isConnected { return lhs.isConnected && !rhs.isConnected }
                    return (lhs.accountEmail ?? "").localizedCaseInsensitiveCompare(rhs.accountEmail ?? "") == .orderedAscending
                }

                return ProviderAccountGroup(
                    id: item.id,
                    providerId: item.id,
                    title: item.title(for: language),
                    subtitle: item.summary(for: language),
                    channel: item.channel,
                    isScanningEnabled: selectedProviderIds.contains(item.id),
                    accounts: sortedEntries
                )
            }
    }

    var hiddenAccounts: [StoredProviderAccount] {
        let providerOrder = providerCatalog.map(\.id)
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
    
    func setupAutoRefresh() {
        refreshTimer?.invalidate()
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        
        if autoRefreshInterval > 0 {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoRefreshInterval), repeats: true) { [weak self] _ in
                self?.refreshAllProviders()
            }
        }
    }
    
    func refreshAllProviders() {
        Task { @MainActor in
            guard !isRefreshingAllProviders else { return }
            isRefreshingAllProviders = true
            defer { isRefreshingAllProviders = false }
            await fetchDashboard()
        }
    }

    func refreshProvider(_ providerId: String) {
        Task { @MainActor in
            await refreshProviderNow(providerId)
        }
    }

    func refreshProviderCard(_ provider: ProviderData) {
        Task {
            await refreshProviderCardNow(provider)
        }
    }

    @MainActor
    func refreshProviderCardNow(_ provider: ProviderData) async {
        if let credentialId = credentialID(for: provider) {
            await refreshAccountNow(credentialId: credentialId, providerId: provider.baseProviderId)
        } else {
            await refreshProviderNow(provider.baseProviderId)
        }
    }

    func refreshAccount(credentialId: String, providerId: String) {
        Task {
            await refreshAccountNow(credentialId: credentialId, providerId: providerId)
        }
    }

    @MainActor
    func refreshProviderNow(_ providerId: String) async {
        guard selectedProviderIds.contains(providerId),
              !refreshingProviderIDs.contains(providerId) else { return }
        refreshingProviderIDs.insert(providerId)
        defer { refreshingProviderIDs.remove(providerId) }
        await fetchSingleProvider(providerId)
        completeProviderRefresh(providerId: providerId, at: Date())
    }

    @MainActor
    func refreshAccountNow(credentialId: String, providerId: String) async {
        guard selectedProviderIds.contains(providerId) else { return }
        let refreshKey = accountRefreshKey(providerId: providerId, credentialId: credentialId)
        guard !refreshingAccountIDs.contains(refreshKey) else { return }
        refreshingAccountIDs.insert(refreshKey)
        defer { refreshingAccountIDs.remove(refreshKey) }
        await fetchAccountByCredential(credentialId: credentialId, providerId: providerId)
        let refreshedAt = Date()
        accountRefreshTimes[refreshKey] = refreshedAt
        if let refreshedProvider = providers.first(where: {
            $0.baseProviderId == providerId && credentialID(for: $0) == credentialId
        }) {
            markAccountRefreshed(refreshedProvider, at: refreshedAt)
        }
    }

    @MainActor
    private func fetchAccountByCredential(credentialId: String, providerId: String) async {
        guard backendMode == "local" else {
            await fetchSingleProvider(providerId)
            return
        }
        guard let result = await engine.fetchForCredential(providerId: providerId, credentialId: credentialId),
              let summary = result.summary else { return }
        let converted = localizeProviderData(convertSummary(summary))
        reconcileAccountRegistry(with: [converted])

        if let index = providers.firstIndex(where: { $0.id == converted.id }) {
            providers[index] = converted
        } else if let index = providers.firstIndex(where: {
            $0.baseProviderId == providerId && $0.id.contains(credentialId)
        }) {
            providers[index] = converted
        } else if !isProviderHidden(converted) {
            providers.append(converted)
            providers = providers.sorted(by: providerSort)
        }
    }

    @MainActor
    private func syncUnifiedManagedAccounts(for providerIds: [String]) async {
        guard backendMode == "local" else { return }

        let uniqueProviderIDs = Array(Set(providerIds)).sorted()
        guard !uniqueProviderIDs.isEmpty else { return }

        for providerId in uniqueProviderIDs {
            let candidates = ProviderAuthManager.unmanagedCandidates(for: providerId)
            guard !candidates.isEmpty else { continue }

            for candidate in candidates {
                let backoffKey = discoveryBackoffKey(for: candidate)
                if let retryAfter = discoveryFailureBackoff[backoffKey], retryAfter > Date() {
                    continue
                }

                do {
                    let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
                    if shouldSuppressAutoManagedAccount(providerId: providerId, usage: usage) {
                        discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                        continue
                    }

                    try registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    discoveryFailureBackoff.removeValue(forKey: backoffKey)
                } catch {
                    discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                }
            }
        }
    }

    private func discoveryBackoffKey(for candidate: ProviderAuthCandidate) -> String {
        [
            candidate.providerId,
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            candidate.title.lowercased()
        ].joined(separator: "|")
    }

    private func shouldSuppressAutoManagedAccount(providerId: String, usage: ProviderUsage) -> Bool {
        let normalizedEmail = normalizedAccountLookupValue(
            usage.accountEmail?.nilIfBlank
                ?? usage.accountLogin?.nilIfBlank
                ?? usage.accountName?.nilIfBlank
        )
        let normalizedAccountId = normalizedAccountLookupValue(
            usage.usageAccountId?.nilIfBlank
                ?? usage.accountLogin?.nilIfBlank
        )

        return accountRegistry.contains { stored in
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

    @MainActor
    func fetchSingleProvider(_ providerId: String) async {
        guard selectedProviderIds.contains(providerId) else { return }
        if backendMode == "local" {
            await fetchSingleProviderLocal(providerId)
        } else {
            await fetchSingleProviderRemote(providerId)
        }
    }

    @MainActor
    private func fetchSingleProviderLocal(_ providerId: String) async {
        await syncUnifiedManagedAccounts(for: [providerId])

        if let results = await engine.fetchMultiAccountProvider(id: providerId) {
            print("[fetchSingleProviderLocal] \(providerId): got \(results.count) results")
            for r in results {
                print("  result id=\(r.id) ok=\(r.ok) accountId=\(r.resultAccountId ?? "nil") error=\(r.error ?? "none") hasSummary=\(r.summary != nil)")
            }
            let convertedResults = results.compactMap { result -> ProviderData? in
                guard let summary = result.summary else { return nil }
                return localizeProviderData(convertSummary(summary))
            }
            let stabilizedResults = stabilizedBulkRefreshProviders(convertedResults, preservingExistingFor: providerId)
            print("[fetchSingleProviderLocal] \(providerId): \(convertedResults.count) converted, registry=\(accountRegistry.filter { $0.providerId == providerId }.map { "[\($0.email) cred=\($0.credentialId ?? "nil") hidden=\($0.isHidden) resultId=\($0.providerResultId ?? "nil")]" })")
            reconcileAccountRegistry(with: stabilizedResults)
            let visible = visibleProviders(from: stabilizedResults)
            print("[fetchSingleProviderLocal] \(providerId): \(visible.count) visible (of \(stabilizedResults.count) stabilized)")
            replaceProviderEntries(for: providerId, with: visible)
        } else if let result = await engine.fetchSingle(id: providerId),
                  let summary = result.summary {
            let converted = localizeProviderData(convertSummary(summary))
            reconcileAccountRegistry(with: [converted])
            replaceProviderEntries(for: providerId, with: visibleProviders(from: [converted]))
        }
    }

    @MainActor
    private func fetchSingleProviderRemote(_ providerId: String) async {
        APIService.shared.updateBaseURL("http://\(remoteHost):\(remotePort)")
        do {
            let updatedProviders = try await APIService.shared.fetchProviders(providerId)
            let localizedProviders = updatedProviders.map(localizeProviderData)
            reconcileAccountRegistry(with: localizedProviders)
            replaceProviderEntries(for: providerId, with: visibleProviders(from: localizedProviders))
        } catch {
            sendErrorNotification("Remote refresh failed for \(providerId): \(error.localizedDescription)")
            if !providers.contains(where: { $0.baseProviderId == providerId }) {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    @MainActor
    func fetchDashboard() async {
        let isInitialLoad = providers.isEmpty && overview == nil
        if isInitialLoad { isLoading = true }
        errorMessage = nil

        guard !selectedProviderIds.isEmpty else {
            providers = []
            overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                summaries: [],
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )))
            isLoading = false
            return
        }

        if backendMode == "local" {
            await fetchDashboardLocal()
        } else {
            await fetchDashboardRemote()
        }
    }

    @MainActor
    private func fetchDashboardLocal() async {
        await syncUnifiedManagedAccounts(for: selectedProviderIDList())

        let snapshot = await engine.fetchAll(ids: selectedProviderIDList())
        let localizedProviders = snapshot.providers.compactMap { result -> ProviderData? in
            guard let summary = result.summary else { return nil }
            return localizeProviderData(convertSummary(summary))
        }
        let stabilizedProviders = stabilizedBulkRefreshProviders(localizedProviders)
        reconcileAccountRegistry(with: stabilizedProviders)
        self.providers = visibleProviders(from: stabilizedProviders)
        self.overview = localizeOverview(convertOverview(snapshot.overview))
        completeGlobalRefresh(
            providerIds: selectedProviderIDList(),
            providers: self.providers,
            at: Date()
        )
        self.isLoading = false
    }

    @MainActor
    private func fetchDashboardRemote() async {
        APIService.shared.updateBaseURL("http://\(remoteHost):\(remotePort)")
        do {
            let dashboard = try await APIService.shared.fetchDashboard(providerIds: selectedProviderIDList())
            let localizedProviders = dashboard.providers.compactMap { wrapper -> ProviderData? in
                localizeProviderData(wrapper.summary)
            }
            let stabilizedProviders = stabilizedBulkRefreshProviders(localizedProviders)
            reconcileAccountRegistry(with: stabilizedProviders)
            self.providers = visibleProviders(from: stabilizedProviders)
            self.overview = localizeOverview(dashboard.overview)
            completeGlobalRefresh(
                providerIds: selectedProviderIDList(),
                providers: self.providers,
                at: Date()
            )
            self.isLoading = false
        } catch {
            self.isLoading = false
            if providers.isEmpty {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func saveSelectedProviderIds() {
        UserDefaults.standard.set(selectedProviderIDList(), forKey: Self.selectedProvidersKey)
    }

    func providerRefreshDate(for providerId: String) -> Date? {
        if let refreshedAt = providerRefreshTimes[providerId] {
            return refreshedAt
        }

        return providers
            .filter { $0.baseProviderId == providerId }
            .compactMap { accountRefreshDate(for: $0) }
            .max()
    }

    func accountRefreshDate(for provider: ProviderData) -> Date? {
        for key in accountRefreshKeys(for: provider) {
            if let refreshedAt = accountRefreshTimes[key] {
                return refreshedAt
            }
        }

        guard let fetchedAt = provider.fetchedAt else { return nil }
        return parseISO8601(fetchedAt)
    }

    func isProviderRefreshInFlight(_ providerId: String) -> Bool {
        isRefreshingAllProviders || refreshingProviderIDs.contains(providerId)
    }

    func isRefreshInProgress(for provider: ProviderData) -> Bool {
        if isRefreshingAllProviders || refreshingProviderIDs.contains(provider.baseProviderId) {
            return true
        }

        return accountRefreshKeys(for: provider).contains { refreshingAccountIDs.contains($0) }
    }

    private func selectedProviderIDList() -> [String] {
        providerCatalog.map(\.id).filter { selectedProviderIds.contains($0) }
    }

    private func sanitizedProviderIDs<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
        let validIDs = Set(Self.providerCatalogItems.map(\.id))
        return Set(ids.filter { validIDs.contains($0) })
    }

    private func replaceProviderEntries(for providerId: String, with replacements: [ProviderData]) {
        providers.removeAll { $0.baseProviderId == providerId }
        providers.append(contentsOf: replacements)
        providers = providers.sorted(by: providerSort)
    }

    private func completeGlobalRefresh(
        providerIds: [String],
        providers: [ProviderData],
        at refreshedAt: Date
    ) {
        lastRefreshTime = refreshedAt
        for providerId in providerIds {
            providerRefreshTimes[providerId] = refreshedAt
        }
        for provider in providers {
            markAccountRefreshed(provider, at: refreshedAt)
        }
    }

    private func completeProviderRefresh(providerId: String, at refreshedAt: Date) {
        providerRefreshTimes[providerId] = refreshedAt
        for provider in providers where provider.baseProviderId == providerId {
            markAccountRefreshed(provider, at: refreshedAt)
        }
    }

    private func markAccountRefreshed(_ provider: ProviderData, at refreshedAt: Date) {
        for key in accountRefreshKeys(for: provider) {
            accountRefreshTimes[key] = refreshedAt
        }
    }

    private func accountRefreshKeys(for provider: ProviderData) -> [String] {
        var keys: [String] = []

        func append(_ key: String?) {
            guard let key, !keys.contains(key) else { return }
            keys.append(key)
        }

        if let credentialId = credentialID(for: provider)?.nilIfBlank {
            append(accountRefreshKey(providerId: provider.baseProviderId, credentialId: credentialId))
        }

        if let storedAccount = accountRegistry.first(where: {
            !$0.isHidden && storedAccountMatchesLive($0, provider: provider)
        }) {
            append(accountRefreshKey(providerId: provider.baseProviderId, storedAccountId: storedAccount.id))
        }

        if let normalizedAccountId = normalizedAccountLookupValue(provider.accountId) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: "account:\(normalizedAccountId)"))
        }

        if let normalizedLabel = normalizedAccountLookupValue(provider.accountLabel ?? provider.label) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: "label:\(normalizedLabel)"))
        }

        append(accountRefreshKey(providerId: provider.baseProviderId, providerDataId: provider.id))
        return keys
    }

    private func accountRefreshKey(providerId: String, credentialId: String) -> String {
        "\(providerId):cred:\(credentialId.lowercased())"
    }

    private func accountRefreshKey(providerId: String, storedAccountId: String) -> String {
        "\(providerId):stored:\(storedAccountId.lowercased())"
    }

    private func accountRefreshKey(providerId: String, identity: String) -> String {
        "\(providerId):identity:\(identity.lowercased())"
    }

    private func accountRefreshKey(providerId: String, providerDataId: String) -> String {
        "\(providerId):live:\(providerDataId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func stabilizedBulkRefreshProviders(
        _ incomingProviders: [ProviderData],
        preservingExistingFor targetProviderId: String? = nil
    ) -> [ProviderData] {
        let groupedIncoming = Dictionary(grouping: incomingProviders, by: \.baseProviderId)
        let providerIDs = targetProviderId.map { [$0] } ?? Array(Set(incomingProviders.map(\.baseProviderId)))

        var stabilized: [ProviderData] = []
        for providerId in providerIDs {
            let incoming = groupedIncoming[providerId] ?? []
            stabilized.append(contentsOf: stabilizedBulkRefreshProviders(for: providerId, incoming: incoming))
        }

        return deduplicatedProvidersByID(stabilized).sorted(by: providerSort)
    }

    private func stabilizedBulkRefreshProviders(
        for providerId: String,
        incoming: [ProviderData]
    ) -> [ProviderData] {
        let storedAccounts = accountRegistry.filter { $0.providerId == providerId && !$0.isHidden }
        guard !storedAccounts.isEmpty else {
            return deduplicatedProvidersByID(incoming)
        }

        let existingProviders = providers.filter { $0.baseProviderId == providerId }
        var remainingIncoming = incoming
        var selected: [ProviderData] = []

        for storedAccount in storedAccounts {
            let incomingMatches = remainingIncoming.filter { storedAccountMatchesLive(storedAccount, provider: $0) }
            let existingMatches = existingProviders.filter { storedAccountMatchesLive(storedAccount, provider: $0) }

            let incomingBest = preferredLiveProvider(among: incomingMatches, storedAccount: storedAccount)
            let existingBest = preferredLiveProvider(among: existingMatches, storedAccount: storedAccount)
            if let chosen = preferredBulkRefreshProvider(incoming: incomingBest, existing: existingBest) {
                selected.append(chosen)
            }

            if !incomingMatches.isEmpty {
                let consumedIDs = Set(incomingMatches.map(\.id))
                remainingIncoming.removeAll { consumedIDs.contains($0.id) }
            }
        }

        let unmatchedIncoming = Dictionary(grouping: remainingIncoming, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }

        selected.append(contentsOf: unmatchedIncoming)
        return deduplicatedProvidersByID(selected)
    }

    private func preferredBulkRefreshProvider(
        incoming: ProviderData?,
        existing: ProviderData?
    ) -> ProviderData? {
        if let incoming, incoming.status != .error {
            return incoming
        }

        if let existing, existing.status != .error {
            return existing
        }

        return incoming ?? existing
    }

    private func deduplicatedProvidersByID(_ providers: [ProviderData]) -> [ProviderData] {
        var seen = Set<String>()
        var deduplicated: [ProviderData] = []

        for provider in providers where seen.insert(provider.id).inserted {
            deduplicated.append(provider)
        }

        return deduplicated
    }

    private func buildProviderEntries(
        providerId: String,
        providerTitle: String,
        providerSubtitle: String?,
        liveProviders: [ProviderData],
        storedAccounts: [StoredProviderAccount]
    ) -> [ProviderAccountEntry] {
        var remainingLive = liveProviders
        var entries: [ProviderAccountEntry] = []

        for stored in storedAccounts {
            let matches = remainingLive.filter { storedAccountMatchesLive(stored, provider: $0) }

            if let preferredLive = preferredLiveProvider(among: matches, storedAccount: stored) {
                let consumedIDs = Set(matches.map(\.id))
                remainingLive.removeAll { consumedIDs.contains($0.id) }
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: preferredLive,
                        storedAccount: stored
                    )
                )
            } else {
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: nil,
                        storedAccount: stored
                    )
                )
            }
        }

        let unmatchedLive = Dictionary(grouping: remainingLive, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }

        for live in unmatchedLive {
            entries.append(
                ProviderAccountEntry(
                    id: live.id,
                    providerId: providerId,
                    providerTitle: providerTitle,
                    providerSubtitle: providerSubtitle,
                    liveProvider: live,
                    storedAccount: nil
                )
            )
        }

        return entries
    }

    private func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let providerOrder = providerCatalog.map(\.id)
        let lhsProviderIndex = providerOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsProviderIndex = providerOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsProviderIndex != rhsProviderIndex {
            return lhsProviderIndex < rhsProviderIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }

    private func reconcileAccountRegistry(with providers: [ProviderData]) {
        var didChange = false
        let now = ISO8601DateFormatter().string(from: Date())
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

    private func deduplicateAccountRegistry() {
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

    private func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    private struct CredentialAccountSnapshot {
        let accountHandle: String?
        let displayName: String?
        let accountId: String?
        let validatedAt: String?

        var normalizedAccountId: String? {
            accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
        }
    }

    private func credentialAccountSnapshot(providerId: String, credentialId: String) -> CredentialAccountSnapshot? {
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
    private func normalizeAccountRegistryAgainstCredentials() -> Bool {
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

    private func bootstrapCredentialIndexFromRegistry() {
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

    private func bestCredentialMatch(
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

    private func storedAccountIdentityKey(_ account: StoredProviderAccount) -> String {
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

    private func shouldPreferStoredAccount(
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

    private func mergedStoredAccount(
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

    private func maxTimestampString(_ values: String?...) -> String? {
        values
            .compactMap { $0?.nilIfBlank }
            .max {
                (parseISO8601($0) ?? .distantPast) < (parseISO8601($1) ?? .distantPast)
            }
    }

    private func credentialID(for provider: ProviderData) -> String? {
        if let direct = extractCredentialId(from: provider.id) {
            return direct
        }

        return accountRegistry.first(where: {
            !$0.isHidden && storedAccountMatchesLive($0, provider: provider)
        })?.credentialId?.nilIfBlank
    }

    private func bestStoredAccountIndex(
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

    private func storedAccountMatchesLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        guard stored.providerId == provider.baseProviderId else { return false }
        let _dbg = stored.providerId == "gemini"
        if _dbg { print("[matchLive] stored=\(stored.email) cred=\(stored.credentialId ?? "nil") hidden=\(stored.isHidden) resultId=\(stored.providerResultId ?? "nil") vs live=\(provider.id) label=\(provider.accountLabel ?? "nil")") }

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
           let liveAccountId = normalizedLiveAccountID(for: provider),
           storedAccountId == liveAccountId {
            return true
        }

        if let liveEmail = normalizedAccountIdentifier(for: provider),
           stored.normalizedEmail == liveEmail {
            return true
        }

        return false
    }

    private func bestStoredAccountIndex(for entry: ProviderAccountEntry) -> Int? {
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

    private func makeStoredAccount(
        from entry: ProviderAccountEntry,
        note: String?,
        isHidden: Bool,
        lastSeenAt: String?
    ) -> StoredProviderAccount? {
        let now = ISO8601DateFormatter().string(from: Date())
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

    private func visibleProviders(from providers: [ProviderData]) -> [ProviderData] {
        providers.filter { !isProviderHidden($0) }
    }

    private func isProviderHidden(_ provider: ProviderData) -> Bool {
        let hasHiddenMatch = accountRegistry.contains { $0.isHidden && storedAccountMatchesLive($0, provider: provider) }
        guard hasHiddenMatch else { return false }
        let hasVisibleMatch = accountRegistry.contains { !$0.isHidden && storedAccountMatchesLive($0, provider: provider) }
        return !hasVisibleMatch
    }

    private func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    private func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        guard let raw = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    private func liveProviderIdentity(_ provider: ProviderData) -> String {
        if let accountId = normalizedLiveAccountID(for: provider) {
            return "\(provider.baseProviderId):id:\(accountId)"
        }
        if let label = normalizedAccountIdentifier(for: provider) {
            return "\(provider.baseProviderId):label:\(label)"
        }
        return "\(provider.baseProviderId):result:\(provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func preferredLiveProvider(
        among candidates: [ProviderData],
        storedAccount: StoredProviderAccount?
    ) -> ProviderData? {
        candidates.max { lhs, rhs in
            let lhsScore = liveProviderScore(lhs, storedAccount: storedAccount)
            let rhsScore = liveProviderScore(rhs, storedAccount: storedAccount)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return providerSort(lhs, rhs)
        }
    }

    private func liveProviderScore(
        _ provider: ProviderData,
        storedAccount: StoredProviderAccount?
    ) -> Int {
        var score = 0

        if provider.status != .error {
            score += 80
        }
        if provider.accountId?.nilIfBlank != nil {
            score += 20
        }
        if provider.accountLabel?.nilIfBlank != nil {
            score += 20
        }
        if provider.membershipLabel?.nilIfBlank != nil {
            score += 10
        }
        if provider.remainingPercent != nil {
            score += 5
        }
        score += min(provider.metrics.count, 3) * 2
        score += min(provider.windows.count, 3) * 3

        if provider.id.contains(":cred:") {
            score += 8
        }
        if provider.id.contains(":auto:") {
            score += 4
        }

        guard let storedAccount else { return score }

        let liveID = provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let credentialId = storedAccount.credentialId?.nilIfBlank,
           extractCredentialId(from: provider.id) == credentialId {
            score += 400
        }

        if let storedResultId = storedAccount.normalizedProviderResultId {
            if storedResultId == liveID {
                score += 300
            } else if liveID.hasPrefix(storedResultId + ":") || storedResultId.hasPrefix(liveID + ":") {
                score += 240
            }
        }

        if let storedAccountId = storedAccount.normalizedAccountId,
           let liveAccountId = normalizedLiveAccountID(for: provider),
           storedAccountId == liveAccountId {
            score += 160
        }

        if storedAccount.normalizedEmail == normalizedAccountIdentifier(for: provider) {
            score += 120
        }

        return score
    }

    private func matchingCredentials(for entry: ProviderAccountEntry) -> [AccountCredential] {
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

    private func matchingStoredAccountIndices(for entry: ProviderAccountEntry) -> [Int] {
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

    private func accountIdentityTokens(for entry: ProviderAccountEntry) -> Set<String> {
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

    private func persistAccountRegistry() {
        try? SecureAccountVault.shared.saveAccounts(accountRegistry)
    }

    private func cleanupManagedCredentialArtifacts() {
        let credentials = AccountCredentialStore.shared.loadAllCredentials()
        guard !credentials.isEmpty else { return }
        ProviderManagedImportStore.cleanupOrphanedManagedImports(referencedBy: credentials)
    }

    // MARK: - Provider Account Activation

    static let activatableProviders: Set<String> = ["codex", "gemini"]

    @Published var activeProviderAccountIds: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: "activeProviderAccountIds"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            if let legacyCodex = UserDefaults.standard.string(forKey: "activeCodexAccountId") {
                return ["codex": legacyCodex]
            }
            return [:]
        }
        return dict
    }()
    @Published var activationResult: ActivationResult?

    var activeCodexAccountId: String? {
        get { activeProviderAccountIds["codex"] }
        set {
            activeProviderAccountIds["codex"] = newValue
            persistActiveIds()
        }
    }
    @Published var codexActivationResult: CodexActivationResult?

    enum CodexActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    enum ActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    private func persistActiveIds() {
        if let data = try? JSONEncoder().encode(activeProviderAccountIds) {
            UserDefaults.standard.set(data, forKey: "activeProviderAccountIds")
        }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        Self.activatableProviders.contains(providerId)
    }

    func activateAccount(entry: ProviderAccountEntry) throws {
        switch entry.providerId {
        case "codex":
            try activateCodexAccount(entry: entry)
        case "gemini":
            try activateGeminiAccount(entry: entry)
        default:
            break
        }
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        guard let activeId = activeProviderAccountIds[entry.providerId]?.lowercased() else { return false }
        let candidates = [
            entry.storedAccount?.accountId,
            entry.liveProvider?.accountId,
            entry.accountEmail,
            entry.storedAccount?.email
        ].compactMap { $0?.lowercased().nilIfBlank }
        return candidates.contains(activeId)
    }

    // MARK: Codex activation

    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let codexDir = NSString(string: "~/.codex").expandingTildeInPath
        let targetPath = "\(codexDir)/auth.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel
        let accountId = entry.storedAccount?.accountId
            ?? entry.liveProvider?.accountId

        let resolved = resolveCliProxyOrManagedSource(prefix: "codex", email: email, entry: entry)
        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = language == "zh" ? "找不到该账号的认证文件" : "Auth file not found for this account."
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToCodexNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: nativeData, fm: fm)

        let newActiveId = accountId ?? email
        activeProviderAccountIds["codex"] = newActiveId
        persistActiveIds()

        let label = email ?? accountId ?? "Codex"
        let msg = language == "zh" ? "已切换到 \(label)" : "Switched to \(label)"
        activationResult = .success(msg)
        codexActivationResult = .success(msg)
    }

    // MARK: Gemini / Antigravity activation

    func activateGeminiAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let geminiDir = NSString(string: "~/.gemini").expandingTildeInPath
        let oauthCredsPath = "\(geminiDir)/oauth_creds.json"
        let googleAccountsPath = "\(geminiDir)/google_accounts.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel

        let proxyPrefix = entry.providerId == "antigravity" ? "antigravity" : "gemini"
        let resolved = resolveCliProxyOrManagedSource(prefix: proxyPrefix, email: email, entry: entry)

        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = language == "zh" ? "找不到该账号的认证文件" : "Auth file not found for this account."
            activationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToGeminiNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: geminiDir, targetPath: oauthCredsPath, data: nativeData, fm: fm)

        if let email {
            try updateGeminiActiveAccount(googleAccountsPath: googleAccountsPath, email: email, fm: fm)
        }

        activeProviderAccountIds["gemini"] = email
        persistActiveIds()

        let label = email ?? "Account"
        let msg = language == "zh" ? "已切换到 \(label)" : "Switched to \(label)"
        activationResult = .success(msg)
    }

    private func convertToGeminiNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["refresh_token"] != nil, json["scope"] != nil {
            return data
        }

        if let tokenDict = json["token"] as? [String: Any], let refreshToken = tokenDict["refresh_token"] as? String {
            var native: [String: Any] = [
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
            ]
            if let accessToken = tokenDict["access_token"] as? String { native["access_token"] = accessToken }
            if let idToken = tokenDict["id_token"] as? String { native["id_token"] = idToken }
            if let expiryDate = tokenDict["expiry_date"] as? Int { native["expiry_date"] = expiryDate }
            return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
        }

        if let refreshToken = json["refresh_token"] as? String {
            var native: [String: Any] = [
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
            ]
            if let accessToken = json["access_token"] as? String { native["access_token"] = accessToken }
            if let idToken = json["id_token"] as? String { native["id_token"] = idToken }
            if let expiryDate = json["expiry_date"] as? Int { native["expiry_date"] = expiryDate }
            return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
        }

        return data
    }

    private func updateGeminiActiveAccount(googleAccountsPath: String, email: String, fm: FileManager) throws {
        var accounts: [String: Any]
        if let data = fm.contents(atPath: googleAccountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accounts = json
        } else {
            accounts = [:]
        }

        let previousActive = accounts["active"] as? String
        var oldList = (accounts["old"] as? [String]) ?? []

        if let previousActive, previousActive != email, !oldList.contains(previousActive) {
            oldList.append(previousActive)
        }
        oldList.removeAll { $0 == email }

        accounts["active"] = email
        accounts["old"] = oldList

        let data = try JSONSerialization.data(withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: googleAccountsPath), options: .atomic)
    }

    // MARK: Codex format conversion

    private func convertToCodexNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return data
        }

        var native: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": json["account_id"] ?? "",
                "id_token": json["id_token"] ?? ""
            ] as [String: Any],
            "last_refresh": json["last_refresh"] ?? ISO8601DateFormatter().string(from: Date())
        ]
        native["OPENAI_API_KEY"] = NSNull()

        return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Shared helpers

    private func writeAuthFileWithBackup(targetDir: String, targetPath: String, data: Data, fm: FileManager) throws {
        if !fm.fileExists(atPath: targetDir) {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        let backupPath = "\(targetPath).bak"
        if fm.fileExists(atPath: targetPath) {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: targetPath, toPath: backupPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            if fm.fileExists(atPath: backupPath) {
                try? fm.removeItem(atPath: targetPath)
                try? fm.copyItem(atPath: backupPath, toPath: targetPath)
            }
            let msg = language == "zh" ? "切换失败：\(error.localizedDescription)" : "Switch failed: \(error.localizedDescription)"
            activationResult = .failure(msg)
            throw error
        }
    }

    private func resolveCliProxyOrManagedSource(prefix: String, email: String?, entry: ProviderAccountEntry) -> String? {
        let fm = FileManager.default
        let proxyDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath

        if let email {
            if let freshPath = freshestCliProxyFile(dir: proxyDir, prefix: prefix, email: email, fm: fm) {
                return freshPath
            }
        }

        let credentials = matchingCredentials(for: entry)
        if let credential = credentials.first {
            let candidatePaths: [String?] = [
                credential.authMethod == .authFile ? credential.credential : nil,
                credential.metadata["sourcePath"]
            ]
            for p in candidatePaths.compactMap({ $0?.nilIfBlank }) {
                let expanded = NSString(string: p).expandingTildeInPath
                if fm.fileExists(atPath: expanded) { return expanded }
            }
        }

        return nil
    }

    private func freshestCliProxyFile(dir: String, prefix: String, email: String, fm: FileManager) -> String? {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let emailLower = email.lowercased()
        let matching = files.filter {
            $0.hasPrefix("\(prefix)-") && $0.hasSuffix(".json") && $0.lowercased().contains(emailLower)
        }
        guard !matching.isEmpty else { return nil }

        var best: (path: String, date: Date)?
        for file in matching {
            let fullPath = "\(dir)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if best == nil || modDate > best!.date {
                best = (fullPath, modDate)
            }
        }
        return best?.path
    }

    // MARK: Detection

    func detectActiveCodexAccount() {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let email = json["email"] as? String
        let tokens = json["tokens"] as? [String: Any]
        let accountId = (tokens?["account_id"] as? String)
            ?? (tokens?["accountId"] as? String)
            ?? (json["account_id"] as? String)
            ?? (json["accountId"] as? String)

        let detectedId = accountId ?? email
        if let detectedId, detectedId != activeProviderAccountIds["codex"] {
            activeProviderAccountIds["codex"] = detectedId
            persistActiveIds()
        }
    }

    func detectActiveGeminiAccount() {
        let googleAccountsPath = NSString(string: "~/.gemini/google_accounts.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: googleAccountsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["active"] as? String else {
            return
        }
        if active != activeProviderAccountIds["gemini"] {
            activeProviderAccountIds["gemini"] = active
            persistActiveIds()
        }
    }

    func isActiveCodexAccount(_ entry: ProviderAccountEntry) -> Bool {
        isActiveAccount(entry)
    }

    // MARK: - QuotaBackend → ProviderData conversion

    private func convertSummary(_ s: QuotaBackend.ProviderSummary) -> ProviderData {
        ProviderData(
            id: s.id,
            providerId: s.providerId,
            accountId: s.accountId,
            name: s.name,
            label: s.label,
            description: s.description,
            category: s.category,
            channel: s.channel,
            status: ProviderStatus(rawValue: s.status) ?? .healthy,
            statusLabel: s.statusLabel,
            theme: ProviderTheme(accent: s.theme.accent, glow: s.theme.glow),
            sourceLabel: s.sourceLabel,
            sourceType: s.sourceType,
            fetchedAt: s.fetchedAt,
            accountLabel: s.accountLabel,
            membershipLabel: s.membershipLabel,
            headline: Headline(eyebrow: s.headline.eyebrow, primary: s.headline.primary, secondary: s.headline.secondary, supporting: s.headline.supporting),
            metrics: s.metrics.map { Metric(label: $0.label, value: $0.value, note: $0.note) },
            windows: s.windows.map { QuotaWindow(label: $0.label, remainingPercent: $0.remainingPercent, usedPercent: $0.usedPercent, value: $0.value, note: $0.note, resetAt: $0.resetAt) },
            remainingPercent: s.remainingPercent,
            nextResetAt: s.nextResetAt,
            nextResetLabel: s.nextResetLabel,
            spotlight: s.spotlight,
            models: s.models?.map { ModelInfo(label: $0.label, value: $0.value, note: $0.note) },
            costSummary: s.costSummary.map { cs in
                CostSummary(
                    today: cs.today.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    week:  cs.week.map  { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    month: cs.month.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    timeline: cs.timeline.map { timeline in
                        CostTimeline(
                            hourly: timeline.hourly.map {
                                CostTimelinePoint(bucket: $0.bucket, label: $0.label, usd: $0.usd, tokens: $0.tokens)
                            },
                            daily: timeline.daily.map {
                                CostTimelinePoint(bucket: $0.bucket, label: $0.label, usd: $0.usd, tokens: $0.tokens)
                            }
                        )
                    }
                )
            }
        )
    }

    private func convertOverview(_ o: QuotaBackend.DashboardOverview) -> DashboardOverview {
        DashboardOverview(
            generatedAt: o.generatedAt,
            activeProviders: o.activeProviders,
            attentionProviders: o.attentionProviders,
            criticalProviders: o.criticalProviders,
            resetSoonProviders: o.resetSoonProviders,
            localCostMonthUsd: o.localCostMonthUsd,
            localWeekTokens: o.localWeekTokens,
            stats: o.stats.map { OverviewStat(label: $0.label, value: $0.value, note: $0.note) },
            alerts: o.alerts.map { Alert(tone: $0.tone, providerId: $0.providerId, title: $0.title, body: $0.body) }
        )
    }

    private func localizeProviderData(_ provider: ProviderData) -> ProviderData {
        guard language == "zh" else { return provider }

        return ProviderData(
            id: provider.id,
            providerId: provider.providerId,
            accountId: provider.accountId,
            name: provider.name,
            label: provider.label,
            description: localizedDynamicText(provider.description),
            category: provider.category,
            channel: provider.channel,
            status: provider.status,
            statusLabel: provider.statusLabel,
            theme: provider.theme,
            sourceLabel: localizedDynamicText(provider.sourceLabel),
            sourceType: provider.sourceType,
            fetchedAt: provider.fetchedAt,
            accountLabel: provider.accountLabel,
            membershipLabel: provider.membershipLabel,
            headline: Headline(
                eyebrow: localizedDynamicText(provider.headline.eyebrow),
                primary: localizedDynamicText(provider.headline.primary),
                secondary: localizedDynamicText(provider.headline.secondary),
                supporting: provider.headline.supporting.map(localizedDynamicText)
            ),
            metrics: provider.metrics.map {
                Metric(
                    label: localizedDynamicText($0.label),
                    value: localizedDynamicText($0.value),
                    note: $0.note.map(localizedDynamicText)
                )
            },
            windows: provider.windows.map {
                QuotaWindow(
                    label: localizedDynamicText($0.label),
                    remainingPercent: $0.remainingPercent,
                    usedPercent: $0.usedPercent,
                    value: localizedDynamicText($0.value),
                    note: localizedDynamicText($0.note),
                    resetAt: $0.resetAt
                )
            },
            remainingPercent: provider.remainingPercent,
            nextResetAt: provider.nextResetAt,
            nextResetLabel: provider.nextResetLabel,
            spotlight: provider.spotlight.map(localizedDynamicText),
            models: provider.models?.map {
                ModelInfo(
                    label: $0.label,
                    value: localizedDynamicText($0.value),
                    note: $0.note.map(localizedDynamicText)
                )
            },
            costSummary: provider.costSummary.map { summary in
                CostSummary(
                    today: summary.today.map(localizedCostPeriod),
                    week: summary.week.map(localizedCostPeriod),
                    month: summary.month.map(localizedCostPeriod),
                    timeline: summary.timeline.map { timeline in
                        CostTimeline(
                            hourly: timeline.hourly.map(localizedTimelinePoint),
                            daily: timeline.daily.map(localizedTimelinePoint)
                        )
                    }
                )
            }
        )
    }

    private func localizedCostPeriod(_ period: CostPeriod) -> CostPeriod {
        CostPeriod(
            usd: period.usd,
            tokens: period.tokens,
            rangeLabel: period.rangeLabel.map(localizedDynamicText)
        )
    }

    private func localizedTimelinePoint(_ point: CostTimelinePoint) -> CostTimelinePoint {
        CostTimelinePoint(
            bucket: point.bucket,
            label: localizedDynamicText(point.label),
            usd: point.usd,
            tokens: point.tokens
        )
    }

    private func localizeOverview(_ overview: DashboardOverview) -> DashboardOverview {
        guard language == "zh" else { return overview }

        return DashboardOverview(
            generatedAt: overview.generatedAt,
            activeProviders: overview.activeProviders,
            attentionProviders: overview.attentionProviders,
            criticalProviders: overview.criticalProviders,
            resetSoonProviders: overview.resetSoonProviders,
            localCostMonthUsd: overview.localCostMonthUsd,
            localWeekTokens: overview.localWeekTokens,
            stats: overview.stats.map {
                OverviewStat(
                    label: localizedDynamicText($0.label),
                    value: localizedDynamicText($0.value),
                    note: localizedDynamicText($0.note)
                )
            },
            alerts: overview.alerts.map {
                Alert(
                    tone: $0.tone,
                    providerId: $0.providerId,
                    title: localizedDynamicText($0.title),
                    body: localizedDynamicText($0.body)
                )
            }
        )
    }

    private func localizedDynamicText(_ text: String) -> String {
        guard language == "zh", !text.isEmpty else { return text }

        let exact: [String: String] = [
            "Connected Sources": "监控服务",
            "Attention Queue": "状态提醒",
            "Tracked Local Cost": "费用追踪",
            "Resets In 24h": "即将刷新",
            "Tracked Services": "监控服务",
            "Live Accounts": "在线账号",
            "Cost Tracking": "费用追踪",
            "Status Alerts": "状态提醒",
            "Live snapshot": "实时快照",
            "Fetched successfully": "抓取成功",
            "This provider is connected.": "该服务已连接。",
            "Collection failed": "采集失败",
            "Unavailable": "不可用",
            "Check local auth or provider session": "请检查本地登录态或服务会话",
            "Unknown source": "未知来源",
            "Environment variable": "环境变量",
            "Manual credentials": "手动凭证",
            "Browser session": "浏览器会话",
            "Desktop cache": "桌面缓存",
            "CLIProxy auth file": "CLIProxy 授权文件",
            "GitHub CLI": "GitHub CLI",
            "Local CLI session": "本地 CLI 会话",
            "Local Claude logs": "本地 Claude 日志",
            "Gemini CLI OAuth": "Gemini CLI OAuth",
            "Kiro IDE session": "Kiro IDE 会话",
            "Stored credential": "已存凭证",
            "WebView session": "WebView 会话",
            "Pasted cookie": "粘贴的 Cookie",
            "Stored session": "已存会话",
            "Imported credential": "导入的凭证",
            "Saved": "已保存",
            "Awaiting a live session": "等待在线会话",
            "Unknown": "未知",
            "None": "无",
            "Connected": "已连接",
            "Unlimited": "无限",
            "Not available": "暂无",
            "Tracked": "已跟踪",
            "No fixed cap detected": "未检测到固定上限",
            "No cap detected": "未检测到上限",
            "main request reserve": "主额度余量",
            "quota snapshot": "配额快照",
            "Antigravity quota snapshot": "Antigravity 配额快照",
            "lowest remaining model": "剩余最低的模型",
            "Most Copilot lanes are unlimited": "Copilot 大多数通道为无限制",
            "tightest Copilot lane": "最紧张的 Copilot 通道",
            "Kiro usage snapshot": "Kiro 用量快照",
            "tightest Kiro lane": "最紧张的 Kiro 通道",
            "Usage snapshot ready": "用量快照已就绪",
            "lowest remaining window": "剩余最低的窗口",
            "Gemini quota snapshot": "Gemini 配额快照",
            "lowest remaining family": "剩余最低的模型组",
            "Cursor usage snapshot": "Cursor 用量快照",
            "tightest remaining allowance": "最紧张的额度窗口",
            "Token telemetry ready": "Token 统计已就绪",
            "lowest remaining token pool": "剩余最低的 Token 池",
            "Unlimited mode": "无限模式",
            "Desktop quota cache": "桌面配额缓存",
            "Local cost telemetry": "本地费用统计",
            "Local spend ledger": "本地费用账本",
            "Account": "账号",
            "Email": "邮箱",
            "Plan": "计划",
            "Reset": "重置",
            "Source": "来源",
            "Project": "项目",
            "Tracked Models": "跟踪模型",
            "Main Pool": "主额度",
            "Assistant Pool": "助手额度",
            "Bonus Credits": "奖励额度",
            "Premium": "Premium",
            "Chat": "聊天",
            "Completions": "补全",
            "Auth": "认证",
            "Region": "区域",
            "Today": "今天",
            "This Week": "本周",
            "This Month": "本月",
            "Scanned Calls": "扫描调用数",
            "Requests": "请求数",
            "Assistant Credits": "助手额度",
            "Main Plan": "主计划",
            "Named Models": "具名模型",
            "Free Quota": "免费额度",
            "Used": "已用",
            "Remaining": "剩余",
            "Hourly Refill": "每小时回补",
            "Included Plan": "套餐额度",
            "On-demand": "按量",
            "Lowest Remaining": "最低剩余",
            "Billing Period": "计费周期",
            "Billing cycle detected": "已检测到账期",
            "Standard Tokens": "标准 Tokens",
            "Premium Tokens": "高级 Tokens",
            "GitHub account": "GitHub 账号",
            "OpenAI account": "OpenAI 账号",
            "Gemini CLI account": "Gemini CLI 账号",
            "Kiro account": "Kiro 账号",
            "Reset unavailable": "重置时间未知",
            "Reset date unknown": "重置日期未知",
            "Everything is within normal range": "目前都在正常范围内",
            "No urgent resets detected": "暂无即将重置的窗口",
            "A few windows are about to roll over": "有些窗口即将重置",
            "Warp can read from local app cache, which makes the panel feel instantaneous and keeps the design centered on what is actually left right now.": "Warp 可以直接读取本地应用缓存，所以面板刷新很快，重点也能放在当前还剩多少。",
            "This tracker reads Claude Code JSONL logs and estimates spend from local usage, so it works best as a cost ledger rather than an official subscription meter.": "这个追踪源会读取 Claude Code 的 JSONL 日志，并根据本地用量估算费用，所以它更适合作为费用账本，而不是官方订阅额度计量器。",
            "Usage-derived Claude Code spend ledger from local logs": "基于本地日志推导的 Claude Code 费用账本",
            "Claude Code Spend": "Claude Code 费用",
            "Local ledgers and usage-derived spend": "本地账本与用量推导费用",
            "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states.": "Copilot 同时存在无限和限额通道。面板会保留无限通道的可见性，但只有有限额的窗口会影响偏低和告急状态。",
            "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting.": "Codex 有多层重叠的限制窗口，所以界面会把它们一起展示，并用最紧张的那个来驱动提醒。",
            "Gemini quota is model-family based, so the dashboard groups the lowest remaining family first and keeps the project context attached.": "Gemini 的配额是按模型族划分的，所以面板会优先展示剩余最低的模型组，并保留项目上下文。",
            "Cursor mixes percent-based allowances with dollar-based plan spend, so the card pairs remaining percentages with included and on-demand spend signals.": "Cursor 同时存在百分比额度和按美元计的套餐消耗，所以卡片会同时展示剩余百分比、套餐内额度和按量消耗信号。",
            "Amp is best viewed as a replenishing credit pool, so the card highlights remaining balance and refill cadence instead of a hard billing period.": "Amp 更适合看成会持续回补的额度池，所以卡片会重点展示剩余额度和回补节奏，而不是固定账期。",
            "Droid usage is token-heavy, so the panel keeps raw token counts visible next to the percentage-based pools.": "Droid 的用量以 token 为主，所以面板会在百分比池旁边保留原始 token 数量。",
            "GitHub Education access": "GitHub 教育权益"
        ]
        if let mapped = exact[text] {
            return mapped
        }

        var result = text
        result = replacingRegex(#"^Plan · (.+)$"#, in: result, template: "计划 · $1")
        result = replacingRegex(#"^Membership · (.+)$"#, in: result, template: "会员 · $1")
        result = replacingRegex(#"^(.+) left$"#, in: result, template: "剩余 $1")
        result = replacingRegex(#"^(.+) used$"#, in: result, template: "已用 $1")
        result = replacingRegex(#"^(\d[\d,]*) total$"#, in: result, template: "总量 $1")
        result = replacingRegex(#"^(\d[\d,]*) duplicate rows removed$"#, in: result, template: "已去重 $1 条")
        result = replacingRegex(#"^(\d[\d,]*) tokens$"#, in: result, template: "$1 个 tokens")
        result = replacingRegex(#"^(\d[\d,]*) tokens this month$"#, in: result, template: "本月 $1 tokens")
        result = replacingRegex(#"^(\d[\d,]*) tokens observed this week$"#, in: result, template: "本周记录 $1 tokens")
        result = replacingRegex(#"^(\d[\d,]*) providers in the mesh$"#, in: result, template: "当前连接 $1 个服务")
        result = replacingRegex(#"^(\d[\d,]*) critical right now$"#, in: result, template: "当前有 $1 个告急")
        result = replacingRegex(#"^(\d[\d,]*) lanes tracked$"#, in: result, template: "跟踪 $1 个通道")
        result = replacingRegex(#"^token expires (.+)$"#, in: result, template: "token 将于 $1 过期")
        result = replacingRegex(#"^(.+) needs attention$"#, in: result, template: "$1 需要关注")
        result = replacingRegex(#"^(.+) is getting tight$"#, in: result, template: "$1 余额趋紧")
        result = replacingRegex(#"^(.+) has unpriced models$"#, in: result, template: "$1 有未定价模型")
        result = replacingRegex(#"^(.+) • Reset unavailable$"#, in: result, template: "$1 • 重置时间未知")
        result = replacingRegex(#"^(.+) • Resets soon$"#, in: result, template: "$1 • 即将重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)d (\d+)h$"#, in: result, template: "$1 • $2天$3小时后重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)h (\d+)m$"#, in: result, template: "$1 • $2小时$3分钟后重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)m$"#, in: result, template: "$1 • $2分钟后重置")
        result = replacingRegex(#"^Resets soon$"#, in: result, template: "即将重置")
        result = replacingRegex(#"^Resets in (\d+)d (\d+)h$"#, in: result, template: "$1天$2小时后重置")
        result = replacingRegex(#"^Resets in (\d+)h (\d+)m$"#, in: result, template: "$1小时$2分钟后重置")
        result = replacingRegex(#"^Resets in (\d+)m$"#, in: result, template: "$1分钟后重置")
        result = replacingRegex(#"^Antigravity auth files detected: (\d[\d,]*)\. This snapshot uses the most recently updated file \((.+)\)\.$"#,
                                in: result,
                                template: "检测到 $1 个 Antigravity 授权文件，当前快照使用的是最近更新的那个（$2）。")
        result = replacingRegex(#"^Antigravity exposes per-model quotas, so the dashboard keeps each model separate and puts the tightest ones first\.$"#,
                                in: result,
                                template: "Antigravity 提供按模型拆分的配额，所以面板会保留每个模型的独立窗口，并把最紧张的那些放在前面。")
        result = replacingRegex(#"^Kiro reported (\d[\d,]*) usage lanes\. This card shows the three tightest ones first so attention stays on the lanes that will run out soonest\.$"#,
                                in: result,
                                template: "Kiro 报告了 $1 个用量通道，这张卡片会优先展示最紧张的三个，方便你先关注最先见底的通道。")
        result = replacingRegex(#"^Kiro usage is pulled from the same AWS-backed endpoint the desktop app uses, so this snapshot reflects the live agentic request lanes exposed by the app\.$"#,
                                in: result,
                                template: "Kiro 的用量来自桌面应用同一个 AWS 接口，所以这个快照能反映应用当前暴露出来的实时 agent 请求通道。")
        result = replacingRegex(#"^Resets (.+) at (.+)$"#, in: result, template: "重置于 $1 $2")
        result = replacingRegex(#"^(.+) bonus credits remain$"#, in: result, template: "剩余 $1 奖励额度")
        result = replacingRegex(#"^Week (.+) • Today (.+)$"#, in: result, template: "本周 $1 • 今日 $2")
        return result
    }

    private func replacingRegex(_ pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
    
    private func sendErrorNotification(_ message: String) {
        // 错误通过 errorMessage 在 UI 内展示，不使用系统通知避免 XPC 解码警告
        print("AIUsage error: \(message)")
    }
}
