import SwiftUI
import Charts
import QuotaBackend

struct ProxyStatsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: ProxyViewModel

    @AppStorage(DefaultsKey.proxyStatsNodeId) private var selectedNodeIdRaw: String = ""
    @AppStorage(DefaultsKey.proxyStatsModel) private var selectedModelRaw: String = ""
    @AppStorage(DefaultsKey.proxyStatsGranularity) private var granularity: StatGranularity = .daily
    @AppStorage(DefaultsKey.proxyStatsMetric) private var metric: StatMetric = .cost
    @AppStorage(DefaultsKey.proxyStatsDistributionMetric) private var distributionMetric: StatMetric = .cost
    @State private var contentWidth: CGFloat = 0
    @State private var expandedModels: Set<String> = []

    private var nodeBinding: Binding<String> {
        Binding(get: { selectedNodeIdRaw }, set: { selectedNodeIdRaw = $0 })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { selectedModelRaw }, set: { selectedModelRaw = $0 })
    }
    private var selectedNodeId: String? { selectedNodeIdRaw.isEmpty ? nil : selectedNodeIdRaw }
    private var selectedModel: String? { selectedModelRaw.isEmpty ? nil : selectedModelRaw }
    private func validateSelections() {
        if !selectedNodeIdRaw.isEmpty,
           !viewModel.configurations.contains(where: { $0.id == selectedNodeIdRaw }) {
            selectedNodeIdRaw = ""
        }
        if !selectedModelRaw.isEmpty,
           !viewModel.allUpstreamModels(nodeFilter: selectedNodeId).contains(selectedModelRaw) {
            selectedModelRaw = ""
        }
    }

    enum StatGranularity: String, CaseIterable { case hourly, daily }
    enum StatMetric: String, CaseIterable { case cost, tokens }
    private enum InsightsLayout {
        case split
        case stacked
    }

    private struct TrendSeriesDescriptor: Identifiable {
        let model: String
        let points: [ProxyViewModel.ModelTimePoint]
        let totalCost: Double
        let totalTokens: Int

        var id: String { model }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.configurations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        filterBar
                        summaryStrip
                        trendChart
                        insightPanels
                    }
                    .padding(20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: ProxyStatsContentWidthPreferenceKey.self, value: proxy.size.width)
                        }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { validateSelections() }
        .onChange(of: selectedNodeIdRaw) { _, _ in validateSelections() }
        .onPreferenceChange(ProxyStatsContentWidthPreferenceKey.self) { newWidth in
            contentWidth = newWidth
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(L("No proxy nodes configured", "尚未配置代理节点"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L("Add a proxy node in Claude Code Proxy to start tracking usage.",
                   "在 Claude Code 代理中添加节点后即可开始统计用量。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Text(L("Proxy Stats", "代理统计"))
                .font(.title2.weight(.bold))

            Spacer()

            Picker(L("Node", "节点"), selection: nodeBinding) {
                Text(L("All Nodes", "全部节点")).tag("")
                ForEach(viewModel.configurations, id: \.id) { config in
                    Text(config.name).tag(config.id)
                }
            }
            .frame(width: 160)

            Picker(L("Model", "模型"), selection: modelBinding) {
                Text(L("All Models", "全部模型")).tag("")
                ForEach(viewModel.allUpstreamModels(nodeFilter: selectedNodeId), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(width: 160)
        }
    }

    // MARK: - Summary

    private var stats: (cost: Double, tokens: Int, requests: Int, successRate: Double) {
        viewModel.overallStats(nodeFilter: selectedNodeId, modelFilter: selectedModel)
    }

    private var dateRange: (earliest: Date?, latest: Date?, days: Int) {
        viewModel.dataDateRange(nodeFilter: selectedNodeId, modelFilter: selectedModel)
    }

    private static let bannerDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        return df
    }()

    private var dataRangeBanner: some View {
        let range = dateRange
        let retentionDays = UserDefaults.standard.integer(forKey: DefaultsKey.proxyLogRetentionDays)
        let effectiveDays = retentionDays > 0 ? retentionDays : 30
        let df = Self.bannerDateFormatter

        return Group {
            if let earliest = range.earliest {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L("Data covers \(range.days) day(s) (\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))). Logs auto-clean after \(effectiveDays) days.",
                           "数据覆盖 \(range.days) 天（\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))）。日志 \(effectiveDays) 天后自动清理。"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            }
        }
    }

    private var summaryStrip: some View {
        let s = stats
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                summaryCell(icon: "dollarsign.circle.fill",
                            title: L("Cost (\(dateRange.days)d)", "费用（\(dateRange.days)天）"),
                            value: formatCurrency(s.cost), tint: .orange)
                summaryCell(icon: "bolt.fill",
                            title: L("Tokens (\(dateRange.days)d)", "Tokens（\(dateRange.days)天）"),
                            value: formatCompactNumber(Double(s.tokens)), tint: .purple)
                summaryCell(icon: "arrow.up.arrow.down", title: L("Request Count", "请求数"),
                            value: "\(s.requests)", tint: .blue)
                summaryCell(icon: "checkmark.seal.fill", title: L("Success Rate", "成功率"),
                            value: String(format: "%.1f%%", s.successRate), tint: .green)
                summaryCell(icon: "cpu", title: L("Models", "模型数"),
                            value: "\(viewModel.modelAggregates(nodeFilter: selectedNodeId, modelFilter: selectedModel).count)",
                            tint: .pink)
            }
            dataRangeBanner
        }
    }

    private func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Trend Chart

    private var modelTimeSeries: [ProxyViewModel.ModelTimePoint] {
        viewModel.modelTimeSeries(nodeFilter: selectedNodeId, granularity: granularity == .hourly ? "hourly" : "daily")
    }

    private var maxVisibleTrendModels: Int { 8 }

    private var rankedTrendSeries: [TrendSeriesDescriptor] {
        Dictionary(grouping: modelTimeSeries, by: \.model)
            .map { model, points in
                let sortedPoints = points.sorted { $0.date < $1.date }
                return TrendSeriesDescriptor(
                    model: model,
                    points: sortedPoints,
                    totalCost: sortedPoints.reduce(0) { $0 + $1.cost },
                    totalTokens: sortedPoints.reduce(0) { $0 + $1.tokens }
                )
            }
            .sorted { lhs, rhs in
                let lhsValue = metric == .cost ? lhs.totalCost : Double(lhs.totalTokens)
                let rhsValue = metric == .cost ? rhs.totalCost : Double(rhs.totalTokens)
                if lhsValue == rhsValue {
                    return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                }
                return lhsValue > rhsValue
            }
    }

    private var displayedTrendSeries: [TrendSeriesDescriptor] {
        if let selectedModel {
            return rankedTrendSeries.filter { $0.model == selectedModel }
        }
        return Array(rankedTrendSeries.prefix(maxVisibleTrendModels))
    }

    private var hiddenTrendSeriesCount: Int {
        max(0, rankedTrendSeries.count - displayedTrendSeries.count)
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Spend Trend", "消费趋势"))
                    .font(.headline.weight(.bold))
                Spacer()
                Picker("", selection: $metric) {
                    Text(L("Cost", "费用")).tag(StatMetric.cost)
                    Text("Tokens").tag(StatMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("", selection: $granularity) {
                    Text(L("Hourly", "小时")).tag(StatGranularity.hourly)
                    Text(L("Daily", "每日")).tag(StatGranularity.daily)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            let series = displayedTrendSeries
            if series.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                proxyTrendChart(for: series)
                    .frame(height: 260)

                VStack(alignment: .leading, spacing: 8) {
                    if hiddenTrendSeriesCount > 0 && selectedModel == nil {
                        Text(
                            L(
                                "Showing Top \(series.count) models by current metric",
                                "按当前指标仅显示前 \(series.count) 个模型"
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    if series.count > 1 {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(series) { descriptor in
                                StatsLegendChip(
                                    color: colorForProxyModel(descriptor.model),
                                    title: descriptor.model,
                                    value: metric == .cost
                                        ? formatCurrency(descriptor.totalCost)
                                        : formatCompactNumber(Double(descriptor.totalTokens))
                                )
                                .help(descriptor.model)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Model Distribution

    private var rawModelData: [ProxyViewModel.ModelAggregate] {
        viewModel.modelAggregates(nodeFilter: selectedNodeId, modelFilter: selectedModel)
    }

    private var modelData: [ProxyViewModel.ModelAggregate] {
        rawModelData.sorted { lhs, rhs in
            let lhsValue = distributionMetric == .cost ? lhs.cost : Double(lhs.tokens)
            let rhsValue = distributionMetric == .cost ? rhs.cost : Double(rhs.tokens)
            if lhsValue == rhsValue {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    private let chartColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .red, .yellow, .mint, .indigo]

    private var usesStackedInsightsLayout: Bool {
        contentWidth > 0 && contentWidth < 1080
    }

    private var splitDistributionWidth: CGFloat {
        let availableWidth = max(contentWidth, 980)
        return min(max(availableWidth * 0.34, 320), 380)
    }

    private var insightPanels: some View {
        Group {
            if usesStackedInsightsLayout {
                VStack(alignment: .leading, spacing: 16) {
                    modelDistribution(layout: .stacked)
                    modelTable(layout: .stacked)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    modelDistribution(layout: .split)
                        .frame(width: splitDistributionWidth, alignment: .topLeading)
                    modelTable(layout: .split)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
            }
        }
    }

    private func distributionChartHeight(for layout: InsightsLayout) -> CGFloat {
        layout == .split ? 210 : 225
    }

    private func tableColumnWidth(_ column: ProxyStatsTableColumn, layout: InsightsLayout) -> CGFloat {
        switch (layout, column) {
        case (.split, .cost): return 88
        case (.split, .tokens): return 86
        case (.split, .share): return 62
        case (.split, .trend): return 70
        case (.stacked, .cost): return 94
        case (.stacked, .tokens): return 92
        case (.stacked, .share): return 68
        case (.stacked, .trend): return 76
        }
    }

    private func colorForProxyModel(_ model: String) -> Color {
        chartColors[stablePaletteIndex(for: model, paletteCount: chartColors.count)]
    }

    private func distributionValue(_ item: ProxyViewModel.ModelAggregate) -> Double {
        distributionMetric == .cost ? item.cost : Double(item.tokens)
    }

    private func distributionShare(_ item: ProxyViewModel.ModelAggregate) -> Double {
        let total = modelData.reduce(0.0) { $0 + distributionValue($1) }
        guard total > 0 else { return 0 }
        return distributionValue(item) / total * 100
    }

    private func distributionValueText(_ item: ProxyViewModel.ModelAggregate) -> String {
        distributionMetric == .cost
            ? formatCurrency(item.cost)
            : formatCompactNumber(Double(item.tokens))
    }

    private func proxySparklineValues(_ model: String) -> [Double] {
        rankedTrendSeries.first(where: { $0.model == model })?.points.map {
            metric == .cost ? $0.cost : Double($0.tokens)
        } ?? []
    }

    private func proxyTrendChart(for series: [TrendSeriesDescriptor]) -> some View {
        Chart {
            ForEach(series) { descriptor in
                let color = colorForProxyModel(descriptor.model)

                ForEach(descriptor.points, id: \.id) { point in
                    let value = metric == .cost ? point.cost : Double(point.tokens)

                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value(metric == .cost ? "Cost" : "Tokens", value)
                    )
                    .foregroundStyle(color.opacity(series.count == 1 ? 0.22 : 0.12))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(metric == .cost ? "Cost" : "Tokens", value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(Color.primary.opacity(0.1))
                AxisValueLabel {
                    if metric == .cost {
                        Text(formatCurrency(value.as(Double.self) ?? 0))
                            .font(.system(size: 9, design: .monospaced))
                    } else {
                        Text(formatCompactNumber(value.as(Double.self) ?? 0))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(Color.primary.opacity(0.1))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatAxisDate(date))
                            .font(.system(size: 9))
                    }
                }
            }
        }
    }

    private func modelDistribution(layout: InsightsLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Model Distribution", "模型分布"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer()
                    Picker("", selection: $distributionMetric) {
                        Text(L("Cost", "费用")).tag(StatMetric.cost)
                        Text("Tokens").tag(StatMetric.tokens)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                HStack {
                    Picker("", selection: $distributionMetric) {
                        Text(L("Cost", "费用")).tag(StatMetric.cost)
                        Text("Tokens").tag(StatMetric.tokens)
                    }
                    .pickerStyle(.segmented)
                }
            }

            let data = modelData
            if data.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart(Array(data.prefix(6)), id: \.id) { item in
                    SectorMark(
                        angle: .value(distributionMetric == .cost ? "Cost" : "Tokens", max(distributionValue(item), 0.001)),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(colorForProxyModel(item.model))
                    .cornerRadius(4)
                    .annotation(position: .overlay) {
                        let share = distributionShare(item)
                        if share >= 10 {
                            Text(String(format: "%.0f%%", share))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: distributionChartHeight(for: layout))

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(data.prefix(6)), id: \.id) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForProxyModel(item.model))
                                .frame(width: 8, height: 8)
                            Text(item.model)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.model)
                            Spacer()
                            Text(distributionValueText(item))
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(colorForProxyModel(item.model))
                            Text(String(format: "%.1f%%", distributionShare(item)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Model Table

    private func modelTable(layout: InsightsLayout) -> some View {
        let costWidth = tableColumnWidth(.cost, layout: layout)
        let tokensWidth = tableColumnWidth(.tokens, layout: layout)
        let shareWidth = tableColumnWidth(.share, layout: layout)
        let trendWidth = tableColumnWidth(.trend, layout: layout)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Model Details", "模型明细"))
                .font(.headline.weight(.bold))

            let data = modelData
            if data.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(L("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("Cost", "费用")).frame(width: costWidth, alignment: .trailing)
                        Text("Tokens").frame(width: tokensWidth, alignment: .trailing)
                        Text(L("Share", "占比")).frame(width: shareWidth, alignment: .trailing)
                        Text(L("Trend", "趋势")).frame(width: trendWidth, alignment: .center)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(Array(data.enumerated()), id: \.element.id) { index, item in
                        proxyModelRow(
                            item,
                            color: colorForProxyModel(item.model),
                            costWidth: costWidth,
                            tokensWidth: tokensWidth,
                            shareWidth: shareWidth,
                            trendWidth: trendWidth
                        )

                        if expandedModels.contains(item.model) {
                            proxyModelDetailRow(item, color: colorForProxyModel(item.model))
                        }

                        if index < data.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func proxyModelRow(
        _ item: ProxyViewModel.ModelAggregate,
        color: Color,
        costWidth: CGFloat,
        tokensWidth: CGFloat,
        shareWidth: CGFloat,
        trendWidth: CGFloat
    ) -> some View {
        let isExpanded = expandedModels.contains(item.model)

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(item.model)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatCurrency(item.cost))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: costWidth, alignment: .trailing)

            Text(formatCompactNumber(Double(item.tokens)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: tokensWidth, alignment: .trailing)

            Text(String(format: "%.1f%%", distributionShare(item)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: shareWidth, alignment: .trailing)

            MiniSparkline(values: proxySparklineValues(item.model), color: color)
                .frame(width: max(52, trendWidth - 8), height: 20)
                .padding(.leading, 8)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedModels.remove(item.model)
                } else {
                    expandedModels.insert(item.model)
                }
            }
        }
        .background(
            isExpanded
                ? RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08))
                : nil
        )
    }

    private func proxyModelDetailRow(_ item: ProxyViewModel.ModelAggregate, color: Color) -> some View {
        let detailItems: [(String, String, Color)] = [
            (L("Requests", "请求"), "\(item.requests)", .secondary),
            (L("Input", "输入"), formatCompactNumber(Double(item.inputTokens)), .blue),
            (L("Output", "输出"), formatCompactNumber(Double(item.outputTokens)), .green),
            (L("Cache", "缓存"), formatCompactNumber(Double(item.cacheTokens)), .orange)
        ]

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(detailItems, id: \.0) { item in
                proxyMetricPill(label: item.0, value: item.1, color: item.2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(color.opacity(0.04))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func proxyMetricPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }

    // MARK: - Formatting

    private func formatAxisDate(_ date: Date) -> String {
        DateFormat.string(from: date, format: granularity == .hourly ? "HH:mm" : "MM/dd")
    }
}

private enum ProxyStatsTableColumn {
    case cost
    case tokens
    case share
    case trend
}

private struct ProxyStatsContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ProxyStatsView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 900, height: 700)
}
