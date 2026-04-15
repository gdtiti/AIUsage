import SwiftUI
import Charts

// MARK: - Main View

struct CostTrackingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @AppStorage(DefaultsKey.ccStatsGranularity) var selectedGranularity: CostGranularity = .hourly
    @AppStorage(DefaultsKey.ccStatsMetric) var selectedMetric: CostMetric = .usd
    @State var selectedModels: Set<String> = []
    @AppStorage(DefaultsKey.ccStatsDistMetric) var distributionMetric: CostMetric = .usd
    @AppStorage(DefaultsKey.ccStatsDistPeriod) var distributionPeriod: DistributionPeriod = .today
    @State var detailProvider: ProviderData?
    @State var expandedModels: Set<String> = []
    @State var contentWidth: CGFloat = 0

    var costProviders: [ProviderData] {
        refreshCoordinator.providers.filter { $0.category == "local-cost" }
    }

    var primaryProvider: ProviderData? {
        costProviders.first
    }

    var costSummary: CostSummary? {
        primaryProvider?.costSummary
    }

    var models: [ModelCostBreakdown] {
        distributionModels
    }

    var body: some View {
        VStack(spacing: 0) {
            if costProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        summaryStrip
                        chartSection
                        insightPanels
                    }
                    .padding(20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: CostTrackingContentWidthPreferenceKey.self, value: proxy.size.width)
                        }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detailProvider) { provider in
            ProviderDetailView(provider: provider)
        }
        .onPreferenceChange(CostTrackingContentWidthPreferenceKey.self) { newWidth in
            contentWidth = newWidth
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No cost data found", "未发现费用数据"))
                .font(.title3.weight(.bold))
            Text(L("Claude Code usage logs will appear here.", "Claude Code 使用日志将在这里显示。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum CostTrackingInsightsLayout {
    case split
    case stacked
}

private struct CostTrackingContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
