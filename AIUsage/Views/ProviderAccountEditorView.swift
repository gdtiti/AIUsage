import SwiftUI
import QuotaBackend

struct ProviderAccountEditorView: View {
    let providerId: String

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.dismiss) var dismiss
    @StateObject var codexLogin = CodexLoginCoordinator()
    @StateObject var geminiLogin = GeminiLoginCoordinator()
    @State var isWorking = false
    @State var statusMessage: String?
    @State var errorMessage: String?
    @State var showWebLogin = false
    @State var showCodexBrowser = false
    @State var candidates: [ProviderAuthCandidate] = []
    @State var monitoredSources: Set<String> = []
    @State var monitoredFingerprints: Set<String> = []
    @State var monitoredHandles: Set<String> = []
    @State var sessionMonitorTask: Task<Void, Never>?
    var providerTitle: String {
        appState.providerCatalogItem(for: providerId)?.title(for: appState.language) ?? providerId
    }

    var authPlan: ProviderAuthPlan {
        ProviderAuthManager.plan(for: providerId)
    }

    var primaryLaunchAction: ProviderAuthLaunchAction? {
        authPlan.launchActions.first {
            !$0.id.localizedCaseInsensitiveContains("docs")
        } ?? authPlan.launchActions.first
    }

    var showsCodexBrowser: Bool {
        providerId == "codex" && (showCodexBrowser || codexLogin.phase != .idle)
    }

    var showsGeminiLogin: Bool {
        providerId == "gemini" && geminiLogin.phase != .idle
    }

    var editorWidth: CGFloat {
        showsCodexBrowser ? 880 : 520
    }

    var editorHeight: CGFloat {
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
                        Text(L("Connect \(providerTitle) Account", "连接 \(providerTitle) 账号"))
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
                    Label(L("Stored in Keychain", "存入钥匙串"), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(L("Cancel", "取消")) {
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
}
