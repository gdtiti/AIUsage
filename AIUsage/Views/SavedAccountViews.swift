import SwiftUI

struct SavedAccountCard: View {
    let account: ProviderAccountEntry
    var onReconnect: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDetail = false
    @State private var isRefreshing = false

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var hasSecureCredential: Bool {
        account.storedAccount?.credentialId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIconView(account.providerId, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.cardTitle)
                        .font(.headline)
                        .bold()

                    Text(account.cardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let accountLabel = account.footerAccountLabel {
                        Label(accountLabel, systemImage: accountIdentityIcon(for: accountLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if hasSecureCredential {
                        Text(t("Offline", "离线"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.10))
                            .clipShape(Capsule())
                    } else {
                        Text(t("Saved", "已保存"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(
                    hasSecureCredential
                        ? t("Credential may have expired", "凭证可能已过期")
                        : t("Awaiting a live session", "等待在线会话")
                )
                    .font(.title3)
                    .bold()

                if let note = account.accountNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(
                    hasSecureCredential
                        ? t("The stored credential could not fetch live data. Try refreshing or reconnecting.", "已存储的凭证未能获取实时数据。可尝试刷新或重新连接。")
                        : t("Account saved locally. Will auto-match when the app session appears.", "账号已保存到本地。对应应用出现在线会话后会自动匹配。")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if hasSecureCredential {
                    Button {
                        guard !isRefreshing, let credentialId = account.storedAccount?.credentialId else { return }
                        isRefreshing = true
                        appState.refreshAccount(credentialId: credentialId, providerId: account.providerId)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isRefreshing = false }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(t("Retry", "重试"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshing)

                    if let onReconnect {
                        Button(action: onReconnect) {
                            Label(t("Reconnect", "重新连接"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                Spacer()

                if let lastSeen = account.storedAccount?.lastSeenAt,
                   let date = parseISO8601(lastSeen) {
                    Text(formatRelativeTimeFromDate(date, language: appState.language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 180)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
        )
        .onTapGesture { showingDetail = true }
        .sheet(isPresented: $showingDetail) {
            SavedAccountDetailView(account: account, onReconnect: onReconnect)
                .environmentObject(appState)
        }
    }
}

struct SavedAccountDetailView: View {
    let account: ProviderAccountEntry
    var onReconnect: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showingNoteEditor = false
    @State private var showingRemovalAlert = false
    @State private var isRefreshing = false

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var hasSecureCredential: Bool {
        account.storedAccount?.credentialId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ProviderIconView(account.providerId, size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 6) {
                    Text(account.cardTitle)
                        .font(.title2)
                        .bold()

                    Text(account.cardSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let accountLabel = account.footerAccountLabel {
                        Label(accountLabel, systemImage: accountIdentityIcon(for: accountLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if hasSecureCredential {
                        Text(t("Offline", "离线"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.10))
                            .clipShape(Capsule())
                    } else {
                        Text(t("Saved", "已保存"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(t("Account Note", "账号注释"))
                    .font(.headline)

                Text(
                    account.accountNote?.nilIfBlank
                        ?? t("No note yet.", "当前还没有注释。")
                )
                .font(.body)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text(t("Storage", "存储"))
                    .font(.headline)

                Label(
                    hasSecureCredential ? t("Credential stored in Keychain", "凭证已存入钥匙串") : t("Account record stored locally", "账号记录已保存到本地"),
                    systemImage: hasSecureCredential ? "lock.shield" : "tray.full"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let lastSeen = account.storedAccount?.lastSeenAt,
                   let date = parseISO8601(lastSeen) {
                    Text(formatRelativeTimeFromDate(date, language: appState.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if hasSecureCredential {
                    Button {
                        guard !isRefreshing, let credentialId = account.storedAccount?.credentialId else { return }
                        isRefreshing = true
                        appState.refreshAccount(credentialId: credentialId, providerId: account.providerId)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isRefreshing = false }
                    } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(t("Retry Fetch", "重试拉取"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)

                    if let onReconnect {
                        Button {
                            onReconnect()
                            dismiss()
                        } label: {
                            Label(t("Reconnect", "重新连接"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Button {
                    showingNoteEditor = true
                } label: {
                    Label(t("Edit Note", "编辑注释"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showingRemovalAlert = true
                } label: {
                    Label(t("Remove from Monitor", "移出监控"), systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(t("Done", "完成")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingNoteEditor) {
            AccountNoteEditorView(
                providerTitle: account.providerTitle,
                accountLabel: account.cardTitle,
                note: account.accountNote
            ) { updatedNote in
                appState.updateAccountNote(for: account, note: updatedNote)
            }
            .environmentObject(appState)
        }
        .alert(
            t("Remove Account", "删除账号"),
            isPresented: $showingRemovalAlert
        ) {
            Button(t("Delete", "删除"), role: .destructive) {
                appState.deleteAccount(account)
                dismiss()
            }
            Button(t("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(
                hasSecureCredential
                    ? t("This removes the account and its Keychain credential.", "这会移除账号及其钥匙串凭证。")
                    : t("This removes the account from the monitor list.", "这会从监控列表中移除该账号。")
            )
        }
    }
}
