import SwiftUI
import Charts

struct CostTrackingView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedGranularity: CostTimelineGranularity = .hourly
    @State private var selectedMetric: CostTimelineMetric = .usd
    @State private var selectedChartStyle: CostTimelineChartStyle = .hybrid
    @State private var selectedProviderIDs: Set<String> = []
    @State private var focusedProviderID: String?
    @State private var detailProvider: ProviderData?

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if filteredProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        overviewSection
                        visualizationSection
                        sourceLibrarySection
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detailProvider) { provider in
            ProviderDetailView(provider: provider)
        }
        .onAppear(perform: syncProviderSelection)
        .onChange(of: filteredProviderKeys) {
            syncProviderSelection()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(t("Search cost trackers...", "搜索费用追踪..."), text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Spacer()

            Text(t("Visualize local spend as a shared timeline", "用共享时间线来查看本地费用"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var costProviders: [ProviderData] {
        appState.providers.filter { $0.category == "local-cost" }
    }

    private var filteredProviders: [ProviderData] {
        costProviders.filter { provider in
            searchText.isEmpty ||
            provider.name.localizedCaseInsensitiveContains(searchText) ||
            provider.label.localizedCaseInsensitiveContains(searchText) ||
            provider.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredProviderKeys: [String] {
        filteredProviders.map(\.id).sorted()
    }

    private var visibleSeries: [CostDisplaySeries] {
        filteredProviders.compactMap { provider in
            let points = timelinePoints(for: provider)
            guard !points.isEmpty else { return nil }
            return CostDisplaySeries(
                provider: provider,
                color: accentColor(for: provider),
                points: points
            )
        }
        .filter { selectedProviderIDs.contains($0.id) }
    }

    private var summary: CostTrackingSummary {
        CostTrackingSummary(providers: filteredProviders)
    }

    private var selectedSummary: CostTrackingSummary {
        CostTrackingSummary(providers: visibleSeries.map(\.provider))
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Overview", "概览"))
                .font(.title2.weight(.bold))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(t("Cost Tracking", "费用追踪"))
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text(summary.monthCost)
                        .font(.system(size: 38, weight: .bold, design: .rounded))

                    Text(t("Month-to-date across visible local ledgers", "当前可见本地账本的本月累计"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 12)], spacing: 12) {
                        overviewBadge(
                            title: t("Selected", "已选"),
                            value: "\(visibleSeries.count)",
                            tint: .blue,
                            icon: "checkmark.seal.fill"
                        )
                        overviewBadge(
                            title: t("Sources", "来源"),
                            value: "\(filteredProviders.count)",
                            tint: .mint,
                            icon: "square.stack.3d.up.fill"
                        )
                        overviewBadge(
                            title: t("Month Tokens", "本月 Tokens"),
                            value: formatCompactNumber(Double(summary.monthTokensValue)),
                            tint: .orange,
                            icon: "bolt.fill"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(heroBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    CostOverviewMetricCard(
                        title: t("Today", "今天"),
                        value: summary.todayCost,
                        note: summary.todayTokens,
                        tint: .orange,
                        icon: "sun.max.fill"
                    )
                    CostOverviewMetricCard(
                        title: t("This Week", "本周"),
                        value: summary.weekCost,
                        note: summary.weekTokens,
                        tint: .blue,
                        icon: "calendar"
                    )
                    CostOverviewMetricCard(
                        title: t("This Month", "本月"),
                        value: summary.monthCost,
                        note: summary.monthTokens,
                        tint: .purple,
                        icon: "banknote.fill"
                    )
                    CostOverviewMetricCard(
                        title: t("Peak Source", "峰值来源"),
                        value: summary.topSourceName(language: appState.language),
                        note: summary.topSourceValue,
                        tint: .pink,
                        icon: "waveform.path.ecg"
                    )
                }
                .frame(maxWidth: 440)
            }
        }
    }

    private var visualizationSection: some View {
        CostVisualizationPanel(
            title: t("Consumption Timeline", "消耗时间线"),
            subtitle: t(
                "One shared chart for every spend source. Toggle or focus a source below to compare cleanly.",
                "所有费用来源共用一张主图。你可以在下方开关或聚焦某个来源来清晰对比。"
            ),
            granularity: $selectedGranularity,
            metric: $selectedMetric,
            chartStyle: $selectedChartStyle,
            focusedProviderID: focusedProviderID,
            series: visibleSeries,
            summary: selectedSummary,
            language: appState.language
        )
    }

    private var sourceLibrarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("Tracked Sources", "跟踪来源"))
                        .font(.title3.weight(.bold))
                    Text(t("Compact cards control what the main chart shows.", "轻量卡片只负责控制主图显示。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    let visibleIDs = Set(filteredProviders.map(\.id))
                    if selectedProviderIDs == visibleIDs {
                        selectedProviderIDs = visibleIDs.first.map { [$0] } ?? []
                    } else {
                        selectedProviderIDs = visibleIDs
                        focusedProviderID = nil
                    }
                } label: {
                    Text(
                        selectedProviderIDs == Set(filteredProviders.map(\.id))
                            ? t("Solo Mode", "单线模式")
                            : t("Show All", "显示全部")
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                ForEach(filteredProviders) { provider in
                    CostSourceCard(
                        provider: provider,
                        color: accentColor(for: provider),
                        isVisible: selectedProviderIDs.contains(provider.id),
                        isFocused: focusedProviderID == provider.id,
                        granularity: selectedGranularity,
                        metric: selectedMetric,
                        language: appState.language,
                        onToggleVisibility: {
                            toggleProviderVisibility(provider.id)
                        },
                        onFocus: {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                focusedProviderID = focusedProviderID == provider.id ? nil : provider.id
                                if !selectedProviderIDs.contains(provider.id) {
                                    selectedProviderIDs.insert(provider.id)
                                }
                            }
                        },
                        onOpenDetail: {
                            detailProvider = provider
                        }
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 58))
                .foregroundStyle(.secondary)

            Text(t("No local cost sources found", "未发现本地费用来源"))
                .font(.title3.weight(.bold))

            Text(
                t(
                    "When local ledgers such as Claude Code usage logs are available, they will land here as shared time-series spend sources.",
                    "当 Claude Code 这类本地账本可用时，它们会在这里以共享时间序列来源的形式出现。"
                )
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.11, green: 0.16, blue: 0.24),
                        Color(red: 0.13, green: 0.22, blue: 0.20),
                        Color(red: 0.18, green: 0.14, blue: 0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func overviewBadge(title: String, value: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .center, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.76))

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(tint.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private func syncProviderSelection() {
        let visibleIDs = Set(filteredProviders.map(\.id))
        guard !visibleIDs.isEmpty else {
            selectedProviderIDs = []
            focusedProviderID = nil
            return
        }

        selectedProviderIDs.formIntersection(visibleIDs)
        if selectedProviderIDs.isEmpty {
            selectedProviderIDs = visibleIDs
        }

        if let focusedProviderID, !visibleIDs.contains(focusedProviderID) {
            self.focusedProviderID = nil
        }
    }

    private func toggleProviderVisibility(_ providerID: String) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            if selectedProviderIDs.contains(providerID) {
                selectedProviderIDs.remove(providerID)
                if focusedProviderID == providerID {
                    focusedProviderID = nil
                }
            } else {
                selectedProviderIDs.insert(providerID)
            }
        }
    }

    private func accentColor(for provider: ProviderData) -> Color {
        switch provider.providerId {
        case "claude":
            return .orange
        default:
            let palette: [Color] = [.blue, .mint, .pink, .teal, .indigo, .green, .cyan]
            let seed = provider.id.unicodeScalars.reduce(0) { partial, scalar in
                (partial * 31 + Int(scalar.value)) % palette.count
            }
            return palette[seed]
        }
    }

    private func timelinePoints(for provider: ProviderData) -> [CostTimelinePoint] {
        guard let timeline = provider.costSummary?.timeline else { return [] }
        switch selectedGranularity {
        case .hourly:
            return !timeline.hourly.isEmpty ? timeline.hourly : timeline.daily
        case .daily:
            return !timeline.daily.isEmpty ? timeline.daily : timeline.hourly
        }
    }
}

private enum CostTimelineGranularity: String, CaseIterable, Identifiable {
    case hourly
    case daily

    var id: String { rawValue }
}

private enum CostTimelineMetric: String, CaseIterable, Identifiable {
    case usd
    case tokens

    var id: String { rawValue }
}

private enum CostTimelineChartStyle: String, CaseIterable, Identifiable {
    case line
    case bars
    case hybrid

    var id: String { rawValue }
}

private struct CostDisplaySeries: Identifiable {
    let provider: ProviderData
    let color: Color
    let points: [CostTimelinePoint]

    var id: String { provider.id }
}

private struct CostVisualizationPanel: View {
    let title: String
    let subtitle: String
    @Binding var granularity: CostTimelineGranularity
    @Binding var metric: CostTimelineMetric
    @Binding var chartStyle: CostTimelineChartStyle
    let focusedProviderID: String?
    let series: [CostDisplaySeries]
    let summary: CostTrackingSummary
    let language: String

    @Environment(\.colorScheme) private var colorScheme

    private func t(_ en: String, _ zh: String) -> String {
        language == "zh" ? zh : en
    }

    private var resolvedSeries: [CostDisplaySeries] {
        if let focusedProviderID,
           let focused = series.first(where: { $0.id == focusedProviderID }) {
            return [focused] + series.filter { $0.id != focusedProviderID }
        }
        return series
    }

    private var hasMultipleVisibleSeries: Bool {
        series.count > 1
    }

    private var selectedPoints: [CostChartPoint] {
        resolvedSeries.flatMap { series in
            series.points.map { point in
                CostChartPoint(
                    providerID: series.id,
                    providerName: series.provider.label,
                    label: point.label,
                    bucket: point.bucket,
                    usd: point.usd,
                    tokens: Double(point.tokens),
                    color: series.color
                )
            }
        }
    }

    private var referencePoints: [CostTimelinePoint] {
        resolvedSeries.max(by: { $0.points.count < $1.points.count })?.points ?? []
    }

    private var aggregatePoints: [AggregatedCostChartPoint] {
        guard !resolvedSeries.isEmpty else { return [] }

        var order: [String] = []
        var labels: [String: String] = [:]
        var totals: [String: (usd: Double, tokens: Double)] = [:]

        for series in resolvedSeries {
            for point in series.points {
                if labels[point.bucket] == nil {
                    order.append(point.bucket)
                    labels[point.bucket] = point.label
                }
                let current = totals[point.bucket] ?? (0, 0)
                totals[point.bucket] = (current.usd + point.usd, current.tokens + Double(point.tokens))
            }
        }

        return order.map { bucket in
            let total = totals[bucket] ?? (0, 0)
            return AggregatedCostChartPoint(
                bucket: bucket,
                label: labels[bucket] ?? bucket,
                usd: total.usd,
                tokens: total.tokens
            )
        }
    }

    private var emphasisProviderID: String? {
        focusedProviderID ?? (series.count == 1 ? series.first?.id : nil)
    }

    private var xAxisLabels: [String] {
        let points = !referencePoints.isEmpty ? referencePoints : resolvedSeries.flatMap(\.points)
        guard !points.isEmpty else { return [] }
        let desiredCount = granularity == .hourly ? 6 : 7
        let step = max(Int(ceil(Double(points.count) / Double(desiredCount))), 1)

        return points.enumerated().compactMap { index, point in
            let isFirst = index == 0
            let isLast = index == points.count - 1
            return isFirst || isLast || index.isMultiple(of: step) ? point.label : nil
        }
    }

    private var aggregateTint: Color {
        switch metric {
        case .usd:
            return .orange
        case .tokens:
            return .mint
        }
    }

    private var latestAggregatePoint: AggregatedCostChartPoint? {
        aggregatePoints.last
    }

    private var aggregatePeakPoint: AggregatedCostChartPoint? {
        aggregatePoints.max { lhs, rhs in
            activeValue(lhs) < activeValue(rhs)
        }
    }

    private var averageAggregateValue: Double {
        guard !aggregatePoints.isEmpty else { return 0 }
        return aggregatePoints.map(activeValue).reduce(0, +) / Double(aggregatePoints.count)
    }

    private var yUpperBound: Double {
        let peak = max(
            selectedPoints.map(activeValue).max() ?? 0,
            aggregatePoints.map(activeValue).max() ?? 0
        )
        return peak <= 0 ? 1 : peak * 1.18
    }

    private var latestBucketValueText: String {
        aggregateValueLabel(for: latestAggregatePoint)
    }

    private var averageBucketValueText: String {
        guard averageAggregateValue > 0 else { return "—" }
        return formatChartValue(averageAggregateValue)
    }

    private var peakBucketValueText: String {
        aggregateValueLabel(for: aggregatePeakPoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 8) {
                    segmentedControl(
                        title: t("Window", "窗口"),
                        cases: CostTimelineGranularity.allCases,
                        selection: $granularity
                    ) { item in
                        switch item {
                        case .hourly:
                            return t("Hourly", "小时")
                        case .daily:
                            return t("Daily", "每日")
                        }
                    }

                    segmentedControl(
                        title: t("Metric", "指标"),
                        cases: CostTimelineMetric.allCases,
                        selection: $metric
                    ) { item in
                        switch item {
                        case .usd:
                            return "USD"
                        case .tokens:
                            return t("Tokens", "Tokens")
                        }
                    }

                    segmentedControl(
                        title: t("View", "视图"),
                        cases: CostTimelineChartStyle.allCases,
                        selection: $chartStyle
                    ) { item in
                        switch item {
                        case .line:
                            return t("Line", "曲线")
                        case .bars:
                            return t("Bars", "柱状")
                        case .hybrid:
                            return t("Hybrid", "混合")
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                chartMetricPill(
                    title: t("Latest Bucket", "当前区间"),
                    value: latestBucketValueText,
                    note: latestAggregatePoint?.label ?? "—",
                    tint: aggregateTint
                )
                chartMetricPill(
                    title: t("Average", "区间均值"),
                    value: averageBucketValueText,
                    note: granularity == .hourly ? t("Hourly view", "按小时视图") : t("Daily view", "按每日视图"),
                    tint: .blue
                )
                chartMetricPill(
                    title: t("Peak Bucket", "峰值区间"),
                    value: peakBucketValueText,
                    note: aggregatePeakPoint?.label ?? "—",
                    tint: .pink
                )
                chartMetricPill(
                    title: t("Focused", "聚焦"),
                    value: focusedName,
                    note: t("\(series.count) sources visible", "当前显示 \(series.count) 个来源"),
                    tint: .mint
                )
            }

            if selectedPoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(t("No source selected", "当前没有选中来源"))
                        .font(.headline)
                    Text(t("Use the source cards below to bring one or more lines into the chart.", "在下方来源卡中打开一个或多个来源，即可回到主图。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                Chart {
                    if hasMultipleVisibleSeries {
                        aggregateMarks
                    }

                    ForEach(resolvedSeries) { series in
                        chartMarks(for: series)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: xAxisLabels) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                            .foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let label = value.as(String.self) {
                                Text(label)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                            .foregroundStyle(.secondary.opacity(0.18))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(metric == .usd ? chartCurrencyLabel(amount) : formatCompactNumber(amount))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...yUpperBound)
                .chartPlotStyle { plotContent in
                    plotContent
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            aggregateTint.opacity(colorScheme == .dark ? 0.08 : 0.04),
                                            Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.015),
                                            Color.clear
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                }
                .frame(height: 360)

                if !series.isEmpty {
                    flowLegend
                }
            }
        }
        .padding(22)
        .background(panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.32), lineWidth: 1)
        )
    }

    @ChartContentBuilder
    private func chartMarks(for series: CostDisplaySeries) -> some ChartContent {
        let emphasized = emphasisProviderID == nil || emphasisProviderID == series.id
        let shouldShowBars = chartStyle == .bars || (
            chartStyle == .hybrid &&
            !hasMultipleVisibleSeries &&
            (emphasisProviderID == series.id || (emphasisProviderID == nil && self.series.count == 1))
        )
        let shouldShowLine = chartStyle != .bars
        let shouldFillArea = chartStyle != .bars && (
            emphasisProviderID == series.id || (emphasisProviderID == nil && self.series.count == 1)
        )
        let seriesOpacity = emphasized ? 0.96 : 0.24

        if shouldShowBars {
            ForEach(series.points) { point in
                BarMark(
                    x: .value("Bucket", point.label),
                    y: .value(metricAxisTitle, pointValue(point)),
                    width: .fixed(chartStyle == .bars ? 12 : 16)
                )
                .position(by: .value("Source", series.provider.label))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            series.color.opacity(chartStyle == .bars ? (emphasized ? 0.88 : 0.42) : 0.28),
                            series.color.opacity(chartStyle == .bars ? (emphasized ? 0.56 : 0.20) : 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(7)
                .opacity(chartStyle == .bars ? 1 : seriesOpacity)
            }
        }

        if shouldFillArea {
            ForEach(series.points) { point in
                AreaMark(
                    x: .value("Bucket", point.label),
                    y: .value(metricAxisTitle, pointValue(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            series.color.opacity(colorScheme == .dark ? 0.28 : 0.22),
                            series.color.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(seriesOpacity)
            }
        }

        if shouldShowLine {
            ForEach(series.points) { point in
                LineMark(
                    x: .value("Bucket", point.label),
                    y: .value(metricAxisTitle, pointValue(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(series.color)
                .lineStyle(StrokeStyle(lineWidth: emphasized ? 2.8 : 2.0, lineCap: .round, lineJoin: .round))
                .opacity(seriesOpacity)
            }

            if emphasized {
                ForEach(series.points.suffix(1)) { point in
                    PointMark(
                        x: .value("Bucket", point.label),
                        y: .value(metricAxisTitle, pointValue(point))
                    )
                    .foregroundStyle(series.color)
                    .symbolSize(45)
                }
            }
        }
    }

    @ChartContentBuilder
    private var aggregateMarks: some ChartContent {
        let shouldShowBars = chartStyle != .line
        let shouldShowLine = chartStyle != .bars

        if shouldShowBars {
            ForEach(aggregatePoints) { point in
                BarMark(
                    x: .value("Bucket", point.label),
                    y: .value(metricAxisTitle, activeValue(point)),
                    width: .fixed(chartStyle == .bars ? 18 : 24)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            aggregateTint.opacity(chartStyle == .bars ? 0.72 : 0.34),
                            aggregateTint.opacity(chartStyle == .bars ? 0.32 : 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(8)
            }
        }

        if shouldShowLine {
            ForEach(aggregatePoints) { point in
                AreaMark(
                    x: .value("Bucket", point.label),
                    y: .value(metricAxisTitle, activeValue(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            aggregateTint.opacity(colorScheme == .dark ? 0.18 : 0.12),
                            aggregateTint.opacity(0.01)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ForEach(aggregatePoints) { point in
                LineMark(
                    x: .value("Bucket", point.label),
                    y: .value(metricAxisTitle, activeValue(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(aggregateTint.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            if averageAggregateValue > 0 {
                RuleMark(y: .value(metricAxisTitle, averageAggregateValue))
                    .foregroundStyle(aggregateTint.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text(t("Avg", "均值"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(aggregateTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                    }
            }

            if let peak = aggregatePeakPoint {
                PointMark(
                    x: .value("Bucket", peak.label),
                    y: .value(metricAxisTitle, activeValue(peak))
                )
                .foregroundStyle(aggregateTint)
                .symbolSize(64)
                .annotation(position: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Peak", "峰值"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(aggregateValueLabel(for: peak))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(peak.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(aggregateTint.opacity(0.16), lineWidth: 1)
                    )
                }
            }
        }
    }

    private var flowLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(series) { series in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(series.color)
                            .frame(width: 8, height: 8)
                        Text(series.provider.label)
                            .font(.caption.weight(.semibold))
                        if let latest = series.points.last {
                            Text(legendValue(for: latest))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(series.color.opacity(0.10))
                    )
                }
            }
        }
    }

    private var focusedName: String {
        if let focusedProviderID,
           let series = series.first(where: { $0.id == focusedProviderID }) {
            return series.provider.label
        }
        return t("All", "全部")
    }

    private var metricAxisTitle: String {
        switch metric {
        case .usd:
            return "USD"
        case .tokens:
            return "Tokens"
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlBackgroundColor),
                        Color(nsColor: .controlBackgroundColor).opacity(0.92),
                        Color.black.opacity(colorScheme == .dark ? 0.10 : 0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func segmentedControl<T: Hashable & Identifiable>(
        title: String,
        cases: [T],
        selection: Binding<T>,
        label: @escaping (T) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(cases) { item in
                    let isSelected = selection.wrappedValue.id == item.id
                    Button {
                        selection.wrappedValue = item
                    } label: {
                        Text(label(item))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chartMetricPill(title: String, value: String, note: String? = nil, tint: Color) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }

    private func activeValue(_ point: CostChartPoint) -> Double {
        switch metric {
        case .usd:
            return point.usd
        case .tokens:
            return point.tokens
        }
    }

    private func activeValue(_ point: AggregatedCostChartPoint) -> Double {
        switch metric {
        case .usd:
            return point.usd
        case .tokens:
            return point.tokens
        }
    }

    private func pointValue(_ point: CostTimelinePoint) -> Double {
        switch metric {
        case .usd:
            return point.usd
        case .tokens:
            return Double(point.tokens)
        }
    }

    private func peakLabel(_ point: CostChartPoint) -> String {
        "\(point.providerName) · \(point.label)"
    }

    private func aggregateValueLabel(for point: AggregatedCostChartPoint?) -> String {
        guard let point else { return "—" }
        return formatChartValue(activeValue(point))
    }

    private func formatChartValue(_ value: Double) -> String {
        switch metric {
        case .usd:
            return chartCurrencyLabel(value)
        case .tokens:
            return formatCompactNumber(value)
        }
    }

    private func legendValue(for point: CostTimelinePoint) -> String {
        switch metric {
        case .usd:
            return formatCurrency(point.usd)
        case .tokens:
            return formatCompactNumber(Double(point.tokens))
        }
    }

    private func chartCurrencyLabel(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 1 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.1f", value) }
        return String(format: "$%.0f", value)
    }
}

private struct CostChartPoint: Identifiable {
    let providerID: String
    let providerName: String
    let label: String
    let bucket: String
    let usd: Double
    let tokens: Double
    let color: Color

    var id: String { "\(providerID):\(bucket)" }
}

private struct AggregatedCostChartPoint: Identifiable {
    let bucket: String
    let label: String
    let usd: Double
    let tokens: Double

    var id: String { bucket }
}

private struct CostSourceCard: View {
    let provider: ProviderData
    let color: Color
    let isVisible: Bool
    let isFocused: Bool
    let granularity: CostTimelineGranularity
    let metric: CostTimelineMetric
    let language: String
    let onToggleVisibility: () -> Void
    let onFocus: () -> Void
    let onOpenDetail: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ en: String, _ zh: String) -> String {
        language == "zh" ? zh : en
    }

    private var summary: CostSummary? {
        provider.costSummary
    }

    private var sparklineValues: [Double] {
        let timeline = provider.costSummary?.timeline
        let points: [CostTimelinePoint]
        switch granularity {
        case .hourly:
            points = timeline?.hourly.isEmpty == false ? (timeline?.hourly ?? []) : (timeline?.daily ?? [])
        case .daily:
            points = timeline?.daily.isEmpty == false ? (timeline?.daily ?? []) : (timeline?.hourly ?? [])
        }
        return points.map {
            switch metric {
            case .usd:
                return $0.usd
            case .tokens:
                return Double($0.tokens)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.11))
                        .frame(width: 48, height: 48)

                    ProviderIconView(provider.providerId, size: 24)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.label)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)

                    Text(provider.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(action: onOpenDetail) {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button(action: onToggleVisibility) {
                        Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                            .foregroundStyle(isVisible ? color : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(summary?.month.map { formatCurrency($0.usd) } ?? "—")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isVisible ? .primary : .secondary)

                Text(t("Month-to-date", "本月累计"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CostSparkline(values: sparklineValues, color: color, isMuted: !isVisible)
                .frame(height: 42)

            HStack(spacing: 10) {
                sourceMetric(
                    title: t("Today", "今天"),
                    value: summary?.today.map { formatCurrency($0.usd) } ?? "—"
                )
                sourceMetric(
                    title: t("Week", "本周"),
                    value: summary?.week.map { formatCurrency($0.usd) } ?? "—"
                )
                sourceMetric(
                    title: t("Tokens", "Tokens"),
                    value: summary?.month?.tokens.map { formatCompactNumber(Double($0)) } ?? "—"
                )
            }

            HStack(alignment: .center) {
                Text(isVisible ? t("Visible in chart", "已显示在主图") : t("Hidden from chart", "已隐藏"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isVisible ? color : .secondary)

                Spacer()

                if let refreshTimestamp = appState.accountRefreshDate(for: provider) {
                    Text(formatRefreshTimestamp(refreshTimestamp, language: language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(borderColor, lineWidth: isFocused ? 1.4 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture(perform: onFocus)
        .animation(.easeInOut(duration: 0.18), value: isVisible)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlBackgroundColor),
                        color.opacity(isVisible ? (colorScheme == .dark ? 0.12 : 0.07) : 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var borderColor: Color {
        if isFocused {
            return color.opacity(0.72)
        }
        if isVisible {
            return color.opacity(colorScheme == .dark ? 0.26 : 0.16)
        }
        return Color.primary.opacity(0.08)
    }

    private func sourceMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
    }
}

private struct CostSparkline: View {
    let values: [Double]
    let color: Color
    let isMuted: Bool

    var body: some View {
        GeometryReader { geometry in
            let points = sparklinePoints(in: geometry.size)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.07))

                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(
                        color.opacity(isMuted ? 0.35 : 0.92),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                } else if let point = points.first {
                    Circle()
                        .fill(color.opacity(isMuted ? 0.35 : 0.92))
                        .frame(width: 8, height: 8)
                        .position(point)
                } else {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: geometry.size.width - 20, height: 2)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        }
    }

    private func sparklinePoints(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        guard values.count > 1 else {
            return [CGPoint(x: size.width / 2, y: size.height / 2)]
        }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = max(maxValue - minValue, 0.0001)
        let width = max(size.width - 16, 1)
        let height = max(size.height - 16, 1)

        return values.enumerated().map { index, value in
            let x = 8 + width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
            let normalizedY = (value - minValue) / range
            let y = 8 + height * CGFloat(1 - normalizedY)
            return CGPoint(x: x, y: y)
        }
    }
}

private struct CostOverviewMetricCard: View {
    let title: String
    let value: String
    let note: String
    let tint: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)

                Spacer()

                Text(value)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 12)

            Text(title)
                .font(.subheadline.weight(.bold))

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }
}

struct CostTrackingCard: View {
    let provider: ProviderData

    @EnvironmentObject var appState: AppState
    @State private var showingDetail = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        switch provider.providerId {
        case "claude":
            return .orange
        default:
            return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        .frame(width: 50, height: 50)

                    ProviderIconView(provider.providerId, size: 26)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.label)
                        .font(.headline.weight(.bold))
                    Text(provider.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }

            Text(provider.costSummary?.month.map { formatCurrency($0.usd) } ?? "—")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            HStack(spacing: 10) {
                dashboardMetric(title: "Today", value: provider.costSummary?.today.map { formatCurrency($0.usd) } ?? "—")
                dashboardMetric(title: "Week", value: provider.costSummary?.week.map { formatCurrency($0.usd) } ?? "—")
                dashboardMetric(title: "Tokens", value: provider.costSummary?.month?.tokens.map { formatCompactNumber(Double($0)) } ?? "—")
            }

            if let refreshTimestamp = appState.accountRefreshDate(for: provider) {
                Text(formatRefreshTimestamp(refreshTimestamp, language: appState.language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(color.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { showingDetail = true }
        .sheet(isPresented: $showingDetail) {
            ProviderDetailView(provider: provider)
        }
    }

    private func dashboardMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
    }
}

private struct CostTrackingSummary {
    let todayUsd: Double
    let weekUsd: Double
    let monthUsd: Double
    let todayTokensValue: Int
    let weekTokensValue: Int
    let monthTokensValue: Int
    let sourceCount: Int
    let topSource: ProviderData?

    init(providers: [ProviderData]) {
        todayUsd = providers.reduce(0) { $0 + ($1.costSummary?.today?.usd ?? 0) }
        weekUsd = providers.reduce(0) { $0 + ($1.costSummary?.week?.usd ?? 0) }
        monthUsd = providers.reduce(0) { $0 + ($1.costSummary?.month?.usd ?? 0) }
        todayTokensValue = providers.reduce(0) { $0 + ($1.costSummary?.today?.tokens ?? 0) }
        weekTokensValue = providers.reduce(0) { $0 + ($1.costSummary?.week?.tokens ?? 0) }
        monthTokensValue = providers.reduce(0) { $0 + ($1.costSummary?.month?.tokens ?? 0) }
        sourceCount = providers.count
        topSource = providers.max {
            ($0.costSummary?.month?.usd ?? 0) < ($1.costSummary?.month?.usd ?? 0)
        }
    }

    var todayCost: String { formatCurrency(todayUsd) }
    var weekCost: String { formatCurrency(weekUsd) }
    var monthCost: String { formatCurrency(monthUsd) }
    var todayTokens: String { "\(formatNumber(todayTokensValue)) tokens" }
    var weekTokens: String { "\(formatNumber(weekTokensValue)) tokens" }
    var monthTokens: String { "\(formatNumber(monthTokensValue)) tokens" }
    var topSourceValue: String {
        guard let topSource else { return "—" }
        return formatCurrency(topSource.costSummary?.month?.usd ?? 0)
    }

    func topSourceName(language: String) -> String {
        topSource?.label ?? (language == "zh" ? "暂无" : "None")
    }
}

private func formatCompactNumber(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal

    switch abs(value) {
    case 1_000_000...:
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSNumber(value: value / 1_000_000)) ?? "0") + "M"
    case 10_000...:
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSNumber(value: value / 1_000)) ?? "0") + "k"
    case 1_000...:
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: value / 1_000)) ?? "0") + "k"
    default:
        formatter.maximumFractionDigits = value < 100 ? 1 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}
