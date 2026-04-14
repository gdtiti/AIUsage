import SwiftUI
import QuotaBackend

extension ProviderAccountEditorView {

    @ViewBuilder
    var fallbackLaunchSection: some View {
        if let action = primaryLaunchAction {
            VStack(alignment: .leading, spacing: 8) {
                if providerId == "droid" {
                    Text(L(
                        "If the current Droid login is not the account you want, switch it in your browser first, then click connect again.",
                        "如果当前 Droid 登录的不是你要的账号，先在浏览器里切换好，再回来重新连接。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L(
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
    var loginButton: some View {
        if authPlan.supportsEmbeddedWebLogin && ProviderLoginURLs.webLoginProviders.contains(providerId) {
            Button {
                errorMessage = nil
                statusMessage = nil
                showWebLogin = true
            } label: {
                Label(
                    providerId == "droid" ? L("Connect Account", "连接账号") : L("Sign In", "登录"),
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

    var detectedCandidatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Detected Sessions", "已检测到的会话"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    refreshCandidates()
                } label: {
                    Label(L("Refresh", "刷新"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isWorking)
            }

            Text(L(
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

                        Button(L("Connect", "连接")) {
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

    var codexBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if codexLogin.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(codexPhaseLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(L("Cancel Login", "取消登录")) {
                        showCodexBrowser = false
                        codexLogin.cancel()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else if case .succeeded = codexLogin.phase {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L("Login completed", "登录完成"))
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
                    statusMessage = L("Link copied.", "链接已复制。")
                }
            )
        }
    }

    var codexPhaseLabel: String {
        switch codexLogin.phase {
        case .launching:
            return L("Starting...", "启动中...")
        case .waitingForBrowser:
            return L("Complete sign-in below", "请在下方完成登录")
        case .waitingForCompletion:
            return L("Waiting for authentication...", "等待认证完成...")
        default:
            return ""
        }
    }

    // MARK: - Status

    @ViewBuilder
    var statusFeedback: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Connecting...", "连接中..."))
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

    var geminiLoginSection: some View {
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
                    Text(L("Google sign-in completed", "Google 登录已完成"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()

                if geminiLogin.authURL != nil {
                    Button(L("Open Browser Again", "重新打开浏览器")) {
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
                        Text(L("Secure Google Sign-In", "安全的 Google 登录"))
                            .font(.subheadline.weight(.semibold))

                        Text(L(
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

    var geminiPhaseLabel: String {
        switch geminiLogin.phase {
        case .launching:
            return L("Preparing Google sign-in…", "正在准备 Google 登录…")
        case .waitingForBrowser:
            return L("Finish the browser sign-in", "请完成浏览器登录")
        case .waitingForCompletion:
            return L("Waiting for Google callback…", "正在等待 Google 回调…")
        default:
            return ""
        }
    }
}
