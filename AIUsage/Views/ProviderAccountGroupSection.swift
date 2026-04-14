import SwiftUI

struct ProviderAccountGroupSection: View {
    let group: ProviderAccountGroup
    let onAddAccount: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ProviderIconView(group.providerId, size: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.title3)
                        .bold()

                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        pill(
                            text: group.isScanningEnabled ? L("Scanning", "扫描中") : L("Paused", "已暂停"),
                            tint: group.isScanningEnabled ? .green : .orange
                        )
                        pill(text: L("\(group.connectedCount) live", "\(group.connectedCount) 个在线"), tint: .green)
                        pill(text: L("\(group.accounts.count) accounts", "\(group.accounts.count) 个账号"), tint: .blue)
                    }

                    HStack(spacing: 10) {
                        Button {
                            refreshCoordinator.refreshProvider(group.providerId)
                        } label: {
                            Label(
                                refreshCoordinator.isProviderRefreshInFlight(group.providerId)
                                    ? L("Refreshing App", "刷新该应用中")
                                    : L("Refresh App", "刷新该应用"),
                                systemImage: "arrow.clockwise"
                            )
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(refreshCoordinator.isProviderRefreshInFlight(group.providerId))
                        .help(L("Refresh every account under \(group.title)", "刷新 \(group.title) 下的所有账号"))

                        Button {
                            appState.setProviderScanningEnabled(group.providerId, isEnabled: !group.isScanningEnabled)
                        } label: {
                            Label(
                                group.isScanningEnabled ? L("Pause Scan", "暂停扫描") : L("Resume Scan", "恢复扫描"),
                                systemImage: group.isScanningEnabled ? "pause.circle" : "play.circle"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)

                        Button(action: onAddAccount) {
                            Label(L("Connect Account", "连接账号"), systemImage: "plus")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }

                    if let refreshedAt = refreshCoordinator.providerRefreshDate(for: group.providerId) {
                        HStack(spacing: 4) {
                            Text(L("This app updated", "本应用更新于"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            RefreshableTimeView(
                                date: refreshedAt,
                                language: appState.language,
                                font: .caption2,
                                foregroundStyle: .secondary
                            )
                        }
                    }
                }
            }

            if group.accounts.isEmpty {
                EmptyProviderAccountState(group: group, onAddAccount: onAddAccount)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(group.accounts) { account in
                        if let liveProvider = account.liveProvider {
                            ManagedProviderAccountCard(account: account, provider: liveProvider)
                                .environmentObject(appState)
                        } else {
                            SavedAccountCard(account: account, onReconnect: { onAddAccount() })
                                .environmentObject(appState)
                        }
                    }
                }
            }
        }
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }
}

struct EmptyProviderAccountState: View {
    let group: ProviderAccountGroup
    let onAddAccount: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("No account connected yet", "还没有连接账号"))
                .font(.headline)

            Text(
                L(
                    "This app is already in your scan list. Connect one account and AIUsage will start monitoring it here.",
                    "这个应用已经在扫描列表里了。连接任意一个账号后，AIUsage 就会开始在这里监控它。"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(action: onAddAccount) {
                Label(L("Connect Account", "连接账号"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

struct ManagedProviderAccountCard: View {
    let account: ProviderAccountEntry
    let provider: ProviderData

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator

    var body: some View {
        ProviderCard(
            provider: provider,
            titleOverride: account.cardTitle,
            subtitleOverride: account.cardSubtitle,
            footerAccountLabelOverride: account.footerAccountLabel,
            accountEntry: account,
            refreshAction: refreshThisAccount
        )
    }

    private func refreshThisAccount() async {
        await refreshCoordinator.refreshProviderCardNow(provider)
    }
}
