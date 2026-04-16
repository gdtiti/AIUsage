import SwiftUI

// MARK: - Status Bar Item View
// Displays provider icons + quota/cost metrics in the macOS menu bar.
// Embedded via NSHostingView in AppDelegate.setupMenuBar().

struct StatusBarItemView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject var settings: AppSettings

    static let recommendedMaxAccounts = 4

    private var displayMode: MenuBarDisplayMode { settings.menuBarDisplayMode }
    private var metricType: MenuBarMetricType { settings.menuBarMetricType }
    private var pinnedQuotaIds: Set<String> { settings.menuBarPinnedQuotaAccountIds }
    private var pinnedCostIds: Set<String> { settings.menuBarPinnedCostSourceIds }

    private var items: [StatusBarMetricItem] {
        var result: [StatusBarMetricItem] = []

        if metricType.showsQuota {
            result.append(contentsOf: quotaItems)
        }
        if metricType.showsCost {
            result.append(contentsOf: costItems)
        }

        return result
    }

    private var quotaItems: [StatusBarMetricItem] {
        let groups = appState.providerAccountGroups
        var all: [StatusBarMetricItem] = []

        for group in groups {
            for entry in group.accounts where entry.isConnected {
                guard entry.liveProvider?.category != "local-cost" else { continue }
                guard let quota = entry.liveProvider?.remainingPercent else { continue }

                all.append(StatusBarMetricItem(
                    id: entry.id,
                    providerId: group.providerId,
                    quota: quota,
                    cost: nil,
                    icon: nil
                ))
            }
        }

        if pinnedQuotaIds.isEmpty { return [] }
        return all.filter { pinnedQuotaIds.contains($0.id) }
    }

    private var costItems: [StatusBarMetricItem] {
        let groups = appState.providerAccountGroups
        var all: [StatusBarMetricItem] = []

        for group in groups {
            for entry in group.accounts where entry.isConnected {
                guard entry.liveProvider?.category == "local-cost" else { continue }
                guard let cost = entry.liveProvider?.costSummary?.month?.usd else { continue }

                if pinnedCostIds.contains(entry.id) {
                    all.append(StatusBarMetricItem(
                        id: entry.id,
                        providerId: group.providerId,
                        quota: nil,
                        cost: cost,
                        icon: nil
                    ))
                }
            }
        }

        if pinnedCostIds.contains("proxy-stats") {
            let proxyCost = ProxyViewModel.shared.overallStats(nodeFilter: nil, modelFilter: nil).cost
            if proxyCost > 0 {
                all.append(StatusBarMetricItem(
                    id: "proxy-stats",
                    providerId: "proxy",
                    quota: nil,
                    cost: proxyCost,
                    icon: "network"
                ))
            }
        }

        return all
    }

    var body: some View {
        if items.isEmpty {
            fallbackIcon
        } else {
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { statusBarDivider }
                    statusBarEntry(item)
                }
            }
            .fixedSize()
        }
    }

    // MARK: - Subviews

    private var fallbackIcon: some View {
        Image(systemName: "chart.bar.fill")
            .font(.system(size: 15))
    }

    private var statusBarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func statusBarEntry(_ item: StatusBarMetricItem) -> some View {
        HStack(spacing: 4) {
            if displayMode != .metricOnly {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                } else {
                    StatusBarProviderIcon(providerId: item.providerId, size: 16)
                }
            }

            if displayMode != .iconOnly {
                if let quota = item.quota {
                    Text("\(Int(quota))%")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(quotaColor(quota))
                } else if let cost = item.cost {
                    Text(formatCostCompact(cost))
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Helpers

    private func quotaColor(_ percent: Double) -> Color {
        if percent >= 70 { return Color(red: 0.15, green: 0.78, blue: 0.40) }
        if percent >= 35 { return Color(red: 0.96, green: 0.64, blue: 0.18) }
        return Color(red: 0.92, green: 0.25, blue: 0.28)
    }

    private func formatCostCompact(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 1 { return String(format: "$%.2f", usd) }
        if usd < 100 { return String(format: "$%.1f", usd) }
        return String(format: "$%.0f", usd)
    }
}

// MARK: - Data

private struct StatusBarMetricItem: Identifiable {
    let id: String
    let providerId: String
    let quota: Double?
    let cost: Double?
    let icon: String?
}

// MARK: - Status Bar Provider Icon

struct StatusBarProviderIcon: View {
    let providerId: String
    let size: CGFloat

    private var assetName: String {
        switch providerId {
        case "codex": return "openai"
        default: return providerId
        }
    }

    var body: some View {
        Group {
            if let img = NSImage(named: assetName) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
    }
}
