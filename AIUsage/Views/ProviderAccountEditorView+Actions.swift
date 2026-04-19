import SwiftUI
import QuotaBackend

extension ProviderAccountEditorView {

    // MARK: - Actions

    func iconName(for action: ProviderAuthLaunchAction) -> String {
        if providerId == "codex", action.id == "codex-login" { return "globe" }
        if providerId == "gemini", action.id == "gemini-login" { return "globe" }
        if providerId == "antigravity", action.id == "antigravity-login" { return "globe" }
        switch action.kind {
        case .openApp: return "app.badge"
        case .openURL: return "safari"
        case .revealPath: return "folder"
        case .runTerminal: return "terminal"
        }
    }

    func performLaunch(_ action: ProviderAuthLaunchAction) {
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

        if providerId == "antigravity",
           case .runTerminal(let command) = action.kind,
           command == "antigravity" {
            sessionMonitorTask?.cancel()
            antigravityLogin.start()
            return
        }

        do {
            try ProviderAuthManager.launch(action)
            beginWatchingForFreshSession()
            statusMessage = L("Login started. Finish sign-in and it will connect automatically.", "登录已启动，完成后会自动连接。")
        } catch {
            errorMessage = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    // MARK: - Session Discovery

    func refreshCandidates() {
        let monitored = ProviderAuthManager.monitoredSessions(for: providerId)
        monitoredSources = monitored.sourceIdentifiers
        monitoredFingerprints = monitored.sessionFingerprints
        monitoredHandles = monitored.accountHandles
        candidates = ProviderAuthManager.unmanagedCandidates(for: providerId)
    }

    func isAlreadyConnected(_ candidate: ProviderAuthCandidate) -> Bool {
        if candidate.identityScope == .accountScoped,
           monitoredSources.contains(candidate.sourceIdentifier) { return true }
        if let fingerprint = candidate.sessionFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           monitoredFingerprints.contains(fingerprint) { return true }
        let normalizedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitoredHandles.contains(normalizedTitle)
    }

    func handleCodexLoginSuccess() async {
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
                errorMessage = L("Login succeeded in the browser, but AIUsage could not find the new Codex session yet.", "网页登录已经成功，但 AIUsage 暂时还没有找到新的 Codex 会话。")
            }
            return
        }
        await importCandidate(candidate)
    }

    func handleGeminiLoginSuccess() async {
        guard let authFileURL = geminiLogin.importedAuthFileURL else {
            await MainActor.run {
                errorMessage = L("Google sign-in succeeded, but AIUsage could not find the Gemini auth file.", "Google 登录已经成功，但 AIUsage 没有找到 Gemini 的认证文件。")
            }
            return
        }

        let tempCandidate = ProviderAuthCandidate(
            id: "gemini-oauth:\(authFileURL.path)",
            providerId: "gemini",
            sourceIdentifier: "gemini-oauth:\(authFileURL.path)",
            sessionFingerprint: nil,
            title: geminiLogin.accountEmail ?? "Gemini CLI Google Login",
            subtitle: L("Fresh Google login", "新的 Google 登录"),
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

    func handleAntigravityLoginSuccess() async {
        guard let authFileURL = antigravityLogin.importedAuthFileURL else {
            await MainActor.run {
                errorMessage = L("Google sign-in succeeded, but AIUsage could not find the Antigravity auth file.", "Google 登录已经成功，但 AIUsage 没有找到 Antigravity 的认证文件。")
            }
            return
        }

        let tempCandidate = ProviderAuthCandidate(
            id: "antigravity-oauth:\(authFileURL.path)",
            providerId: "antigravity",
            sourceIdentifier: "antigravity-oauth:\(antigravityLogin.accountEmail?.lowercased() ?? authFileURL.path)",
            sessionFingerprint: nil,
            title: antigravityLogin.accountEmail ?? "Antigravity Google Login",
            subtitle: L("Fresh Google login", "新的 Google 登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(tempCandidate)
        await MainActor.run { antigravityLogin.discardImportedSession() }
    }

    func preferredCodexCandidate(
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

    func importCandidate(_ candidate: ProviderAuthCandidate) async {
        sessionMonitorTask?.cancel()
        await withWorkingState {
            let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
            let pid = candidate.providerId
            try await MainActor.run {
                try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                statusMessage = L("Account connected.", "账号已连接。")
                refreshCandidates()
            }
            if !shouldSkipImmediateProviderRefresh(for: pid) {
                _ = await refreshCoordinator.fetchSingleProvider(pid)
            }
            await MainActor.run { dismiss() }
        }
    }

    func importEmbeddedWebSession(cookie: String) async {
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
                statusMessage = L("Account connected.", "账号已连接。")
                refreshCandidates()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { dismiss() }
        }
    }

    func withWorkingState(_ operation: @escaping () async throws -> Void) async {
        await MainActor.run { isWorking = true; errorMessage = nil; statusMessage = nil }
        do {
            try await operation()
        } catch {
            await MainActor.run { errorMessage = SensitiveDataRedactor.redactedMessage(for: error) }
        }
        await MainActor.run { isWorking = false }
    }

    func shouldSkipImmediateProviderRefresh(for providerId: String) -> Bool {
        providerId == "codex"
            || providerId == "gemini"
            || providerId == "amp"
            || providerId == "cursor"
    }

    func beginWatchingForFreshSession() {
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
                statusMessage = L("Still waiting. Click login again to retry.", "仍在等待，再次点击登录重试。")
            }
        }
    }

    func preferredFreshCandidate(
        from discovered: [ProviderAuthCandidate],
        baseline: Set<String>
    ) -> ProviderAuthCandidate? {
        let fresh = discovered.filter { !baseline.contains(candidateSignature($0)) }
        let source = fresh.isEmpty ? discovered : fresh
        return source.sorted {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }.first
    }

    func candidateSignature(_ candidate: ProviderAuthCandidate) -> String {
        [
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            String(Int(candidate.modifiedAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: "|")
    }
}
