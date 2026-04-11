import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    
    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if appState.isLoading {
                    loadingView
                } else if let error = appState.errorMessage {
                    errorView(error)
                } else if let overview = appState.overview {
                    overviewSection(overview)
                    if !serviceProviders.isEmpty {
                        providersGrid(serviceProviders)
                    }
                    if !costTrackingProviders.isEmpty {
                        costTrackingGrid(costTrackingProviders)
                    }
                } else {
                    emptyView
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Overview Section
    
    private func overviewSection(_ overview: DashboardOverview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Overview", "概览"))
                .font(.title2)
                .bold()
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                ForEach(overviewCards(for: overview)) { stat in
                    StatCard(stat: stat)
                }
            }
        }
    }
    
    // MARK: - Alerts Section
    
    private func alertsSection(_ overview: DashboardOverview) -> some View {
        Group {
            if !overview.alerts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("Alerts", "告警"))
                        .font(.title2)
                        .bold()
                    
                    ForEach(overview.alerts) { alert in
                        AlertBanner(alert: alert)
                    }
                }
            }
        }
    }
    
    // MARK: - Providers Grid
    
    private var serviceProviders: [ProviderData] {
        deduplicatedProviders(appState.providers.filter {
            appState.providerCatalogItem(for: $0.baseProviderId)?.kind == .official
        })
    }

    private var costTrackingProviders: [ProviderData] {
        deduplicatedProviders(appState.providers.filter {
            appState.providerCatalogItem(for: $0.baseProviderId)?.kind == .costTracking
        })
    }

    private var selectedOfficialProviderCount: Int {
        appState.providerCatalog.filter {
            $0.kind == .official && appState.selectedProviderIds.contains($0.id)
        }.count
    }

    private var officialAccountGroups: [ProviderAccountGroup] {
        appState.providerAccountGroups.filter {
            appState.providerCatalogItem(for: $0.providerId)?.kind == .official
        }
    }

    private var connectedAccountCount: Int {
        officialAccountGroups.reduce(0) { $0 + $1.connectedCount }
    }

    private var totalAccountCount: Int {
        officialAccountGroups.reduce(0) { $0 + $1.accounts.count }
    }

    private func overviewCards(for overview: DashboardOverview) -> [DashboardSummaryCard] {
        let watchCount = max(0, overview.attentionProviders - overview.criticalProviders)
        let servicesNote: String
        if selectedOfficialProviderCount > 0 {
            servicesNote = t(
                "\(selectedOfficialProviderCount) official apps enabled",
                "已启用 \(selectedOfficialProviderCount) 个官方应用"
            )
        } else {
            servicesNote = t("Choose apps to start scanning", "选择应用后开始扫描")
        }

        let accountNote: String
        if totalAccountCount > 0 {
            accountNote = t(
                "\(formatInt(totalAccountCount)) accounts saved securely",
                "已安全保存 \(formatInt(totalAccountCount)) 个账号"
            )
        } else {
            accountNote = t("No account has been saved yet", "还没有保存账号")
        }

        let costNote: String
        if costTrackingProviders.isEmpty {
            costNote = t("No Claude Code stats source yet", "还没有 Claude Code 统计来源")
        } else {
            costNote = t(
                "\(costTrackingProviders.count) source tracked this week",
                "当前跟踪 \(costTrackingProviders.count) 个费用来源"
            ) + " · " + t(
                "\(formatInt(overview.localWeekTokens)) tokens logged",
                "本周记录 \(formatInt(overview.localWeekTokens)) 个 tokens"
            )
        }

        let statusNote: String
        if overview.attentionProviders == 0 {
            statusNote = t("Everything is within a healthy range", "目前都在正常范围内")
        } else if overview.criticalProviders > 0 && watchCount > 0 {
            statusNote = t(
                "\(overview.criticalProviders) critical, \(watchCount) getting tight",
                "\(overview.criticalProviders) 个告急，\(watchCount) 个余额偏低"
            )
        } else if overview.criticalProviders > 0 {
            statusNote = t(
                "\(overview.criticalProviders) critical right now",
                "当前有 \(overview.criticalProviders) 个告急"
            )
        } else {
            statusNote = t(
                "\(watchCount) windows are getting tight",
                "当前有 \(watchCount) 个额度偏低"
            )
        }

        return [
            DashboardSummaryCard(
                title: t("Tracked Services", "监控服务"),
                value: formatInt(selectedOfficialProviderCount),
                note: servicesNote,
                icon: "square.stack.3d.up.fill",
                color: .blue
            ),
            DashboardSummaryCard(
                title: t("Live Accounts", "在线账号"),
                value: formatInt(connectedAccountCount),
                note: accountNote,
                icon: "person.crop.circle.badge.checkmark",
                color: .green
            ),
            DashboardSummaryCard(
                title: t("Claude Code Stats", "Claude Code 统计"),
                value: formatCurrency(overview.localCostMonthUsd),
                note: costNote,
                icon: "chart.line.uptrend.xyaxis.circle.fill",
                color: .purple
            ),
            DashboardSummaryCard(
                title: t("Status Alerts", "状态提醒"),
                value: formatInt(overview.attentionProviders),
                note: statusNote,
                icon: "bell.badge.fill",
                color: overview.criticalProviders > 0 ? .red : .orange
            )
        ]
    }

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = value >= 1 ? 2 : 4
        formatter.maximumFractionDigits = value >= 1 ? 2 : 4
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func deduplicatedProviders(_ providers: [ProviderData]) -> [ProviderData] {
        var seen = Set<String>()
        var unique: [ProviderData] = []

        for provider in providers {
            if seen.insert(provider.id).inserted {
                unique.append(provider)
            }
        }

        return unique
    }

    private func providersGrid(_ providers: [ProviderData]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Providers", "服务商"))
                .font(.title2)
                .bold()
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(providers) { provider in
                    ProviderCard(
                        provider: provider,
                        subtitleOverride: appState.accountNote(for: provider),
                        refreshAction: { await appState.refreshProviderCardNow(provider) }
                    )
                }
            }
        }
    }

    private func costTrackingGrid(_ providers: [ProviderData]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Claude Code Stats", "Claude Code 统计"))
                .font(.title2)
                .bold()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(providers) { provider in
                    CostTrackingCard(provider: provider)
                }
            }
        }
    }
    
    // MARK: - State Views
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            SmallProgressView()
                .frame(width: 32, height: 32)
            Text(t("Loading dashboard...", "加载中..."))
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text(t("Error", "错误"))
                .font(.title)
                .bold()
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(t("Retry", "重试")) {
                appState.refreshAllProviders()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.bar")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text(appState.selectedProviderIds.isEmpty ? t("No sources selected", "尚未选择扫描来源") : t("No data available", "暂无数据"))
                .font(.title2)
                .bold()

            Text(
                appState.selectedProviderIds.isEmpty
                    ? t("Choose the apps and sources you want to scan first.", "先选择你想扫描的应用和来源。")
                    : t("Start the backend server and refresh", "请启动后端服务后刷新")
            )
                .font(.body)
                .foregroundColor(.secondary)

            if appState.selectedProviderIds.isEmpty {
                Button {
                    appState.providerPickerMode = appState.needsInitialProviderSetup ? .initialSetup : .manage
                } label: {
                    Label(t("Choose Sources", "选择来源"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(t("Refresh", "刷新")) {
                    appState.refreshAllProviders()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stat Card Component

private struct DashboardSummaryCard: Identifiable {
    let title: String
    let value: String
    let note: String
    let icon: String
    let color: Color

    var id: String { title }
}

private struct StatCard: View {
    let stat: DashboardSummaryCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: stat.icon)
                    .foregroundStyle(stat.color)
                    .font(.title3)
                Spacer()
                Text(stat.value)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(stat.color)
            }

            Spacer(minLength: 8)

            Text(stat.title)
                .font(.subheadline)
                .bold()
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            Text(stat.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(14)
        .background(stat.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(stat.color.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Alert Banner Component

struct AlertBanner: View {
    let alert: Alert
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundColor(alertColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title)
                    .font(.headline)
                
                Text(alert.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(alertColor.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(alertColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var alertColor: Color {
        switch alert.tone {
        case "critical": return .red
        case "watch": return .orange
        default: return .blue
        }
    }
    
    private var iconName: String {
        switch alert.tone {
        case "critical": return "exclamationmark.triangle.fill"
        case "watch": return "exclamationmark.circle.fill"
        default: return "info.circle.fill"
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState.shared)
        .frame(width: 900, height: 700)
}
