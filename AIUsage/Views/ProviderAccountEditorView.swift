import SwiftUI
import WebKit
import QuotaBackend

struct ProviderAccountEditorView: View {
    let providerId: String

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var codexLogin = CodexLoginCoordinator()
    @StateObject private var geminiLogin = GeminiLoginCoordinator()
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showWebLogin = false
    @State private var showCodexBrowser = false
    @State private var candidates: [ProviderAuthCandidate] = []
    @State private var monitoredSources: Set<String> = []
    @State private var monitoredFingerprints: Set<String> = []
    @State private var monitoredHandles: Set<String> = []
    @State private var sessionMonitorTask: Task<Void, Never>?

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var providerTitle: String {
        appState.providerCatalogItem(for: providerId)?.title(for: appState.language) ?? providerId
    }

    private var authPlan: ProviderAuthPlan {
        ProviderAuthManager.plan(for: providerId)
    }

    private var primaryLaunchAction: ProviderAuthLaunchAction? {
        authPlan.launchActions.first {
            !$0.id.localizedCaseInsensitiveContains("docs")
        } ?? authPlan.launchActions.first
    }

    private var showsCodexBrowser: Bool {
        providerId == "codex" && (showCodexBrowser || codexLogin.phase != .idle)
    }

    private var showsGeminiLogin: Bool {
        providerId == "gemini" && geminiLogin.phase != .idle
    }

    private var editorWidth: CGFloat {
        showsCodexBrowser ? 880 : 520
    }

    private var editorHeight: CGFloat {
        if showsCodexBrowser { return 580 }
        if showsGeminiLogin { return 360 }

        let visibleCandidateCount = candidates.count
        let detectedSessionExtra = CGFloat(min(visibleCandidateCount, 3)) * 86
        let baseHeight: CGFloat = visibleCandidateCount == 0 ? 300 : 360
        return min(560, baseHeight + detectedSessionExtra)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    ProviderIconView(providerId, size: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Connect \(providerTitle) Account", "连接 \(providerTitle) 账号"))
                            .font(.title3)
                            .bold()

                        Text(appState.language == "zh" ? authPlan.summaryZh : authPlan.summaryEn)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Main login button
                loginButton

                if !candidates.isEmpty {
                    detectedCandidatesSection
                }

                if providerId == "droid", !authPlan.supportsEmbeddedWebLogin {
                    fallbackLaunchSection
                }

                // Codex embedded browser (only when active)
                if showsCodexBrowser {
                    codexBrowserSection
                }

                if showsGeminiLogin {
                    geminiLoginSection
                }

                // Status feedback (single line)
                statusFeedback

                // Footer
                HStack {
                    Label(t("Stored in Keychain", "存入钥匙串"), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(t("Cancel", "取消")) {
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(24)
        }
        .frame(
            width: editorWidth,
            height: editorHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshCandidates() }
        .onDisappear {
            sessionMonitorTask?.cancel()
            codexLogin.cancel()
            geminiLogin.cancel()
        }
        .onReceive(codexLogin.$phase) { phase in
            guard providerId == "codex" else { return }
            if case .succeeded = phase {
                Task { await handleCodexLoginSuccess() }
            } else if case .failed(let message) = phase {
                showCodexBrowser = true
                errorMessage = message
            }
        }
        .onReceive(geminiLogin.$phase) { phase in
            guard providerId == "gemini" else { return }
            if case .succeeded = phase {
                Task { await handleGeminiLoginSuccess() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .sheet(isPresented: $showWebLogin) {
            if let loginURL = ProviderLoginURLs.loginURL(for: providerId) {
                WebLoginView(
                    providerId: providerId,
                    loginURL: loginURL,
                    cookieDomains: ProviderLoginURLs.cookieDomains(for: providerId),
                    cookieNames: ProviderLoginURLs.cookieNames(for: providerId),
                    onComplete: { cookie in
                        Task { await importEmbeddedWebSession(cookie: cookie) }
                    }
                )
                .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private var fallbackLaunchSection: some View {
        if let action = primaryLaunchAction {
            VStack(alignment: .leading, spacing: 8) {
                if providerId == "droid" {
                    Text(t(
                        "If the current Droid login is not the account you want, switch it in your browser first, then click connect again.",
                        "如果当前 Droid 登录的不是你要的账号，先在浏览器里切换好，再回来重新连接。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(t(
                        "Need to switch accounts or refresh the local login?",
                        "如果需要切换账号，或刷新本地登录状态："
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button {
                    performLaunch(action)
                } label: {
                    Label(action.title(for: appState.language), systemImage: iconName(for: action))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Login Button

    @ViewBuilder
    private var loginButton: some View {
        if authPlan.supportsEmbeddedWebLogin && ProviderLoginURLs.webLoginProviders.contains(providerId) {
            Button {
                errorMessage = nil
                statusMessage = nil
                showWebLogin = true
            } label: {
                Label(
                    providerId == "droid" ? t("Connect Account", "连接账号") : t("Sign In", "登录"),
                    systemImage: "globe"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        } else if let action = primaryLaunchAction {
            Button {
                performLaunch(action)
            } label: {
                Label(action.title(for: appState.language), systemImage: iconName(for: action))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        }
    }

    private var detectedCandidatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Detected Sessions", "已检测到的会话"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    refreshCandidates()
                } label: {
                    Label(t("Refresh", "刷新"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isWorking)
            }

            Text(t(
                "AIUsage found local login state for this provider. Connect one of the sessions below directly.",
                "AIUsage 检测到了这个服务商的本地登录状态。你可以直接连接下面的会话。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(candidates) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            if let subtitle = candidate.subtitle?.nilIfBlank {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(candidate.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 12)

                        Button(t("Connect", "连接")) {
                            Task { await importCandidate(candidate) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isWorking)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Codex Browser

    private var codexBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if codexLogin.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(codexPhaseLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(t("Cancel Login", "取消登录")) {
                        showCodexBrowser = false
                        codexLogin.cancel()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else if case .succeeded = codexLogin.phase {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(t("Login completed", "登录完成"))
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                } else {
                    Spacer()
                }
            }

            CodexOAuthBrowserPane(
                loginURL: codexLogin.authURL,
                phase: codexLogin.phase,
                language: appState.language,
                onObservedCallback: { url in
                    codexLogin.noteBrowserNavigation(url)
                },
                onOpenInBrowser: {
                    guard let authURL = codexLogin.authURL else { return }
                    NSWorkspace.shared.open(authURL)
                },
                onCopyLink: {
                    guard let authURL = codexLogin.authURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(authURL.absoluteString, forType: .string)
                    statusMessage = t("Link copied.", "链接已复制。")
                }
            )
        }
    }

    private var codexPhaseLabel: String {
        switch codexLogin.phase {
        case .launching:
            return t("Starting...", "启动中...")
        case .waitingForBrowser:
            return t("Complete sign-in below", "请在下方完成登录")
        case .waitingForCompletion:
            return t("Waiting for authentication...", "等待认证完成...")
        default:
            return ""
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusFeedback: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(t("Connecting...", "连接中..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } else if let statusMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Actions

    private func iconName(for action: ProviderAuthLaunchAction) -> String {
        if providerId == "codex", action.id == "codex-login" { return "globe" }
        if providerId == "gemini", action.id == "gemini-login" { return "globe" }
        switch action.kind {
        case .openApp: return "app.badge"
        case .openURL: return "safari"
        case .revealPath: return "folder"
        case .runTerminal: return "terminal"
        }
    }

    private func performLaunch(_ action: ProviderAuthLaunchAction) {
        errorMessage = nil
        statusMessage = nil

        if providerId == "codex",
           case .runTerminal(let command) = action.kind,
           command == "codex login" {
            showCodexBrowser = true
            sessionMonitorTask?.cancel()
            codexLogin.start()
            return
        }

        if providerId == "gemini",
           case .runTerminal(let command) = action.kind,
           command == "gemini" {
            sessionMonitorTask?.cancel()
            geminiLogin.start()
            return
        }

        do {
            try ProviderAuthManager.launch(action)
            beginWatchingForFreshSession()
            statusMessage = t("Login started. Finish sign-in and it will connect automatically.", "登录已启动，完成后会自动连接。")
        } catch {
            errorMessage = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    // MARK: - Session Discovery

    private func refreshCandidates() {
        let monitored = ProviderAuthManager.monitoredSessions(for: providerId)
        monitoredSources = monitored.sourceIdentifiers
        monitoredFingerprints = monitored.sessionFingerprints
        monitoredHandles = monitored.accountHandles
        candidates = ProviderAuthManager.unmanagedCandidates(for: providerId)
    }

    private func isAlreadyConnected(_ candidate: ProviderAuthCandidate) -> Bool {
        if candidate.identityScope == .accountScoped,
           monitoredSources.contains(candidate.sourceIdentifier) { return true }
        if let fingerprint = candidate.sessionFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           monitoredFingerprints.contains(fingerprint) { return true }
        let normalizedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitoredHandles.contains(normalizedTitle)
    }

    private func handleCodexLoginSuccess() async {
        if let authFileURL = codexLogin.importedAuthFileURL {
            let discoveredCandidates = ProviderAuthManager.discoverCandidates(for: "codex")
            if let matchingCandidate = discoveredCandidates.first(where: { $0.sourcePath == authFileURL.path }) {
                await importCandidate(matchingCandidate)
            } else {
                let candidate = ProviderAuthManager.makeCodexCandidate(authFileURL: authFileURL)
                await importCandidate(candidate)
            }
            await MainActor.run { codexLogin.discardImportedSession() }
            return
        }

        let discoveredCandidates = ProviderAuthManager.discoverCandidates(for: providerId)
        guard let candidate = preferredCodexCandidate(
            from: discoveredCandidates,
            preferredPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath,
            startedAt: codexLogin.startedAt
        ) else {
            await MainActor.run {
                errorMessage = t("Login succeeded in the browser, but AIUsage could not find the new Codex session yet.", "网页登录已经成功，但 AIUsage 暂时还没有找到新的 Codex 会话。")
            }
            return
        }
        await importCandidate(candidate)
    }

    private func handleGeminiLoginSuccess() async {
        guard let authFileURL = geminiLogin.importedAuthFileURL else {
            await MainActor.run {
                errorMessage = t("Google sign-in succeeded, but AIUsage could not find the Gemini auth file.", "Google 登录已经成功，但 AIUsage 没有找到 Gemini 的认证文件。")
            }
            return
        }

        let tempCandidate = ProviderAuthCandidate(
            id: "gemini-oauth:\(authFileURL.path)",
            providerId: "gemini",
            sourceIdentifier: "gemini-oauth:\(authFileURL.path)",
            sessionFingerprint: nil,
            title: geminiLogin.accountEmail ?? "Gemini CLI Google Login",
            subtitle: t("Fresh Google login", "新的 Google 登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(tempCandidate)
        await MainActor.run { geminiLogin.discardImportedSession() }
    }

    private func preferredCodexCandidate(
        from candidates: [ProviderAuthCandidate],
        preferredPath: String? = nil,
        startedAt: Date? = nil
    ) -> ProviderAuthCandidate? {
        guard providerId == "codex" else { return candidates.first }

        let filteredByTime: [ProviderAuthCandidate]
        if let startedAt {
            let threshold = startedAt.addingTimeInterval(-1)
            let fresh = candidates.filter { ($0.modifiedAt ?? .distantPast) >= threshold }
            filteredByTime = fresh.isEmpty ? candidates : fresh
        } else {
            filteredByTime = candidates
        }

        if let preferredPath {
            return filteredByTime.first(where: { $0.sourcePath == preferredPath })
                ?? filteredByTime.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.first
        }

        let defaultPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        return filteredByTime.first(where: { $0.sourcePath == defaultPath })
            ?? filteredByTime.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.first
    }

    private func importCandidate(_ candidate: ProviderAuthCandidate) async {
        sessionMonitorTask?.cancel()
        await withWorkingState {
            let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
            let pid = candidate.providerId
            try await MainActor.run {
                try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                statusMessage = t("Account connected.", "账号已连接。")
                refreshCandidates()
            }
            if !shouldSkipImmediateProviderRefresh(for: pid) {
                await appState.fetchSingleProvider(pid)
            }
            await MainActor.run { dismiss() }
        }
    }

    private func importEmbeddedWebSession(cookie: String) async {
        let authMethod: AuthMethod = providerId == "cursor" ? .webSession : .cookie
        sessionMonitorTask?.cancel()
        await withWorkingState {
            let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                providerId: providerId,
                authMethod: authMethod,
                value: cookie,
                suggestedLabel: nil
            )
            try await MainActor.run {
                try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                statusMessage = t("Account connected.", "账号已连接。")
                refreshCandidates()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { dismiss() }
        }
    }

    private var geminiLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if geminiLogin.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(geminiPhaseLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .succeeded = geminiLogin.phase {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(t("Google sign-in completed", "Google 登录已完成"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()

                if geminiLogin.authURL != nil {
                    Button(t("Open Browser Again", "重新打开浏览器")) {
                        geminiLogin.reopenInBrowser()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("Secure Google Sign-In", "安全的 Google 登录"))
                            .font(.subheadline.weight(.semibold))

                        Text(t(
                            "AIUsage has opened Gemini's official Google sign-in page in your browser. Finish the browser step, then return here and the account will connect automatically.",
                            "AIUsage 已经在浏览器中打开 Gemini 官方 Google 登录页。你只要在浏览器里完成授权，再回到这里，账号就会自动接入。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if let accountEmail = geminiLogin.accountEmail, !accountEmail.isEmpty {
                            Label(accountEmail, systemImage: "person.crop.circle.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(16)
                }
                .frame(height: 148)
        }
    }

    private var geminiPhaseLabel: String {
        switch geminiLogin.phase {
        case .launching:
            return t("Preparing Google sign-in…", "正在准备 Google 登录…")
        case .waitingForBrowser:
            return t("Finish the browser sign-in", "请完成浏览器登录")
        case .waitingForCompletion:
            return t("Waiting for Google callback…", "正在等待 Google 回调…")
        default:
            return ""
        }
    }

    private func withWorkingState(_ operation: @escaping () async throws -> Void) async {
        await MainActor.run { isWorking = true; errorMessage = nil; statusMessage = nil }
        do {
            try await operation()
        } catch {
            await MainActor.run { errorMessage = SensitiveDataRedactor.redactedMessage(for: error) }
        }
        await MainActor.run { isWorking = false }
    }

    private func shouldSkipImmediateProviderRefresh(for providerId: String) -> Bool {
        providerId == "codex"
            || providerId == "gemini"
            || providerId == "amp"
            || providerId == "cursor"
    }

    private func beginWatchingForFreshSession() {
        refreshCandidates()
        let baseline = Set(candidates.map(candidateSignature))
        sessionMonitorTask?.cancel()

        sessionMonitorTask = Task {
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }

                let discovered = ProviderAuthManager.discoverCandidates(for: providerId)
                    .filter { !isAlreadyConnected($0) }
                if let candidate = preferredFreshCandidate(from: discovered, baseline: baseline) {
                    await importCandidate(candidate)
                    return
                }
            }

            await MainActor.run {
                statusMessage = t("Still waiting. Click login again to retry.", "仍在等待，再次点击登录重试。")
            }
        }
    }

    private func preferredFreshCandidate(
        from discovered: [ProviderAuthCandidate],
        baseline: Set<String>
    ) -> ProviderAuthCandidate? {
        let fresh = discovered.filter { !baseline.contains(candidateSignature($0)) }
        let source = fresh.isEmpty ? discovered : fresh
        return source.sorted {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }.first
    }

    private func candidateSignature(_ candidate: ProviderAuthCandidate) -> String {
        [
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            String(Int(candidate.modifiedAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: "|")
    }
}

private struct CodexOAuthBrowserPane: View {
    let loginURL: URL?
    let phase: CodexLoginCoordinator.Phase
    let language: String
    let onObservedCallback: (URL) -> Void
    let onOpenInBrowser: () -> Void
    let onCopyLink: () -> Void

    @State private var isLoading = true
    @State private var currentURL: URL?
    @State private var pageTitle = ""

    private var isCallbackTransitioning: Bool {
        guard let host = currentURL?.host?.lowercased() else { return false }
        return host.contains("localhost") || host.contains("127.0.0.1")
    }

    private func t(_ en: String, _ zh: String) -> String {
        language == "zh" ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pageTitle.nilIfBlank ?? t("OpenAI Sign-In", "OpenAI 登录"))
                        .font(.subheadline.weight(.semibold))
                    if let currentURL {
                        Text(currentURL.host?.nilIfBlank ?? currentURL.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    onCopyLink()
                } label: {
                    Label(t("Copy Link", "复制链接"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(loginURL == nil)

                Button {
                    onOpenInBrowser()
                } label: {
                    Label(t("Open in Browser", "浏览器打开"), systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(loginURL == nil)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let loginURL {
                    CodexOAuthWebView(
                        url: loginURL,
                        isLoading: $isLoading,
                        currentURL: $currentURL,
                        pageTitle: $pageTitle,
                        onNavigation: { navigatedURL in
                            if let navigatedURL, isSuccessfulCallbackURL(navigatedURL) {
                                onObservedCallback(navigatedURL)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if isCallbackTransitioning || phase == .waitingForCompletion || phase == .succeeded {
                        callbackOverlay
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(t("Preparing the official login page…", "正在准备官方登录页面…"))
                            .font(.subheadline.weight(.semibold))
                        Text(t("If nothing appears in a moment, use the button above to open the page in your browser.", "如果稍后仍未出现，请使用上方按钮在浏览器中打开登录页。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                }
            }
            .frame(minHeight: 360)
        }
    }

    private func isSuccessfulCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.contains("localhost") || host.contains("127.0.0.1") else {
            return false
        }

        let path = url.path.lowercased()
        if path.contains("success") || path.contains("callback") {
            return true
        }

        let queryNames = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            $0.name.lowercased()
        })
        return queryNames.contains("id_token")
            || queryNames.contains("access_token")
            || queryNames.contains("code")
    }

    private var callbackOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(t("Completing Codex login…", "正在完成 Codex 登录…"))
                .font(.headline)
            Text(t("You can return to AIUsage now. The account will connect automatically after Codex finishes.", "现在可以回到 AIUsage。Codex 完成收尾后，账号会自动接入。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct CodexOAuthWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?
    @Binding var pageTitle: String
    let onNavigation: (URL?) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url?.absoluteString != url.absoluteString {
            nsView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: CodexOAuthWebView

        init(parent: CodexOAuthWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let requestURL = navigationAction.request.url {
                DispatchQueue.main.async {
                    self.parent.currentURL = requestURL
                    self.parent.onNavigation(requestURL)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.currentURL = webView.url
                self.parent.pageTitle = webView.title ?? ""
                self.parent.onNavigation(webView.url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.pageTitle = webView.title ?? ""
                self.parent.onNavigation(webView.url)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.onNavigation(webView.url)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.onNavigation(webView.url)
            }
        }
    }
}
