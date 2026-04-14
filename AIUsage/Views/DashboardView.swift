import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var proxyVM: ProxyViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if refreshCoordinator.isLoading {
                    loadingView
                } else if let error = refreshCoordinator.errorMessage {
                    errorView(error)
                } else if let overview = refreshCoordinator.overview {
                    overviewSection(overview)
                    if !serviceProviders.isEmpty {
                        providersGrid(serviceProviders)
                    }
                    if !costTrackingProviders.isEmpty {
                        costTrackingGrid(costTrackingProviders)
                    }
                    if !proxyVM.configurations.isEmpty {
                        proxyStatsSection
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
            Text(L("Overview", "概览", key: "dashboard.overview"))
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
                    Text(L("Alerts", "告警", key: "dashboard.alerts"))
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
        deduplicatedProviders(refreshCoordinator.providers.filter {
            appState.providerCatalogItem(for: $0.baseProviderId)?.kind == .official
        })
    }

    private var costTrackingProviders: [ProviderData] {
        deduplicatedProviders(refreshCoordinator.providers.filter {
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
            servicesNote = L(
                "\(selectedOfficialProviderCount) official apps enabled",
                "已启用 \(selectedOfficialProviderCount) 个官方应用"
            )
        } else {
            servicesNote = L("Choose apps to start scanning", "选择应用后开始扫描")
        }

        let accountNote: String
        if totalAccountCount > 0 {
            accountNote = L(
                "\(formatInt(totalAccountCount)) accounts saved securely",
                "已安全保存 \(formatInt(totalAccountCount)) 个账号"
            )
        } else {
            accountNote = L("No account has been saved yet", "还没有保存账号")
        }

        let costNote: String
        if costTrackingProviders.isEmpty {
            costNote = L("No Claude Code stats source yet", "还没有 Claude Code 统计来源")
        } else {
            costNote = L(
                "\(costTrackingProviders.count) source tracked this week",
                "当前跟踪 \(costTrackingProviders.count) 个费用来源"
            ) + " · " + L(
                "\(formatInt(overview.localWeekTokens)) tokens logged",
                "本周记录 \(formatInt(overview.localWeekTokens)) 个 tokens"
            )
        }

        let statusNote: String
        if overview.attentionProviders == 0 {
            statusNote = L("Everything is within a healthy range", "目前都在正常范围内")
        } else if overview.criticalProviders > 0 && watchCount > 0 {
            statusNote = L(
                "\(overview.criticalProviders) critical, \(watchCount) getting tight",
                "\(overview.criticalProviders) 个告急，\(watchCount) 个余额偏低"
            )
        } else if overview.criticalProviders > 0 {
            statusNote = L(
                "\(overview.criticalProviders) critical right now",
                "当前有 \(overview.criticalProviders) 个告急"
            )
        } else {
            statusNote = L(
                "\(watchCount) windows are getting tight",
                "当前有 \(watchCount) 个额度偏低"
            )
        }

        return [
            DashboardSummaryCard(
                title: L("Tracked Services", "监控服务", key: "dashboard.summary.tracked_services"),
                value: formatInt(selectedOfficialProviderCount),
                note: servicesNote,
                icon: "square.stack.3d.up.fill",
                color: .blue
            ),
            DashboardSummaryCard(
                title: L("Live Accounts", "在线账号", key: "dashboard.summary.live_accounts"),
                value: formatInt(connectedAccountCount),
                note: accountNote,
                icon: "person.crop.circle.badge.checkmark",
                color: .green
            ),
            DashboardSummaryCard(
                title: L("Claude Code Stats", "Claude Code 统计", key: "dashboard.summary.cost_tracking"),
                value: formatCurrency(overview.localCostMonthUsd),
                note: costNote,
                icon: "chart.line.uptrend.xyaxis.circle.fill",
                color: .purple
            ),
            {
                let proxyStats = proxyVM.overallStats(nodeFilter: nil, modelFilter: nil)
                let proxyRange = proxyVM.dataDateRange(nodeFilter: nil, modelFilter: nil)
                let proxyNote: String
                if proxyStats.requests == 0 {
                    proxyNote = L("No proxy requests recorded yet", "暂无代理请求记录")
                } else {
                    proxyNote = L(
                        "\(proxyStats.requests) requests over \(proxyRange.days) days · \(proxyVM.modelAggregates(nodeFilter: nil, modelFilter: nil).count) models",
                        "\(proxyRange.days) 天内 \(proxyStats.requests) 次请求 · \(proxyVM.modelAggregates(nodeFilter: nil, modelFilter: nil).count) 个模型"
                    )
                }
                return DashboardSummaryCard(
                    title: L("Proxy Stats", "代理统计", key: "dashboard.summary.proxy_stats"),
                    value: formatCurrency(proxyStats.cost),
                    note: proxyNote,
                    icon: "server.rack",
                    color: .teal
                )
            }(),
            DashboardSummaryCard(
                title: L("Status Alerts", "状态提醒", key: "dashboard.summary.status_alerts"),
                value: formatInt(overview.attentionProviders),
                note: statusNote,
                icon: "bell.badge.fill",
                color: overview.criticalProviders > 0 ? .red : .orange
            )
        ]
    }

    private func formatInt(_ value: Int) -> String {
        formatNumber(value)
    }

    private func formatCurrency(_ value: Double) -> String {
        AIUsage.formatCurrency(value)
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
            Text(L("Providers", "服务商", key: "dashboard.providers"))
                .font(.title2)
                .bold()
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(providers) { provider in
                    ProviderCard(
                        provider: provider,
                        subtitleOverride: appState.accountNote(for: provider),
                        refreshAction: { await refreshCoordinator.refreshProviderCardNow(provider) }
                    )
                }
            }
        }
    }

    private var proxyStatsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Proxy Stats", "代理统计"))
                    .font(.title2)
                    .bold()
                Spacer()
                Button {
                    appState.selectedSection = .proxyStats
                } label: {
                    Text(L("View Details", "查看详情"))
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            let stats = proxyVM.overallStats(nodeFilter: nil, modelFilter: nil)
            let models = proxyVM.modelAggregates(nodeFilter: nil, modelFilter: nil)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                proxyMiniCard(title: L("Cost", "费用"), value: AIUsage.formatCurrency(stats.cost), icon: "dollarsign.circle.fill", tint: .orange)
                proxyMiniCard(title: "Tokens", value: formatCompactNumber(Double(stats.tokens)), icon: "bolt.fill", tint: .purple)
                proxyMiniCard(title: L("Requests", "请求"), value: "\(stats.requests)", icon: "arrow.up.arrow.down", tint: .blue)
                proxyMiniCard(title: L("Success", "成功率"), value: String(format: "%.0f%%", stats.successRate), icon: "checkmark.seal.fill", tint: .green)
            }

            if !models.isEmpty {
                HStack(spacing: 6) {
                    ForEach(models.prefix(4)) { m in
                        HStack(spacing: 4) {
                            Circle().fill(Color.blue.opacity(0.6)).frame(width: 6, height: 6)
                            Text(m.model).font(.caption2).lineLimit(1)
                            Text(AIUsage.formatCurrency(m.cost)).font(.caption2.weight(.medium).monospacedDigit())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))
                    }
                    Spacer()
                }
            }
        }
    }

    private func proxyMiniCard(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.05)))
    }

    private func costTrackingGrid(_ providers: [ProviderData]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Claude Code Stats", "Claude Code 统计"))
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
            Text(L("Loading dashboard...", "加载中..."))
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
            
            Text(L("Error", "错误"))
                .font(.title)
                .bold()
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(L("Retry", "重试")) {
                refreshCoordinator.refreshAllProviders()
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

            Text(appState.selectedProviderIds.isEmpty ? L("No sources selected", "尚未选择扫描来源") : L("No data available", "暂无数据"))
                .font(.title2)
                .bold()

            Text(
                appState.selectedProviderIds.isEmpty
                    ? L("Choose the apps and sources you want to scan first.", "先选择你想扫描的应用和来源。")
                    : L("Start the backend server and refresh", "请启动后端服务后刷新")
            )
                .font(.body)
                .foregroundColor(.secondary)

            if appState.selectedProviderIds.isEmpty {
                Button {
                    appState.providerPickerMode = appState.needsInitialProviderSetup ? .initialSetup : .manage
                } label: {
                    Label(L("Choose Sources", "选择来源"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(L("Refresh", "刷新")) {
                    refreshCoordinator.refreshAllProviders()
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
