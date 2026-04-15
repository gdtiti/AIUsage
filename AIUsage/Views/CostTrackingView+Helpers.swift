import SwiftUI

extension CostTrackingView {

    typealias ChartSeriesDescriptor = (model: String, points: [CostTimelinePoint], totalUsd: Double, totalTokens: Int)

    func aggregateChartPoints() -> [CostTimelinePoint] {
        guard let timeline = costSummary?.timeline else { return [] }
        return selectedGranularity == .hourly
            ? (!timeline.hourly.isEmpty ? timeline.hourly : timeline.daily)
            : (!timeline.daily.isEmpty ? timeline.daily : timeline.hourly)
    }

    func chartPointsForModel(_ model: String) -> [CostTimelinePoint] {
        let modelSeries = costSummary?.modelTimelines?.first { $0.model == model }
        return timelineFromSeries(modelSeries)
    }

    func chartModelSeries() -> [ChartSeriesDescriptor] {
        guard let modelTimelines = costSummary?.modelTimelines else { return [] }
        return modelTimelines.compactMap { series in
            let points = timelineFromSeries(series)
            guard !points.isEmpty else { return nil }
            return (
                model: series.model,
                points: points,
                totalUsd: points.reduce(0) { $0 + $1.usd },
                totalTokens: points.reduce(0) { $0 + $1.tokens }
            )
        }
    }

    func sortedChartSeries() -> [ChartSeriesDescriptor] {
        chartModelSeries().sorted { lhs, rhs in
            let lhsValue = selectedMetric == .usd ? lhs.totalUsd : Double(lhs.totalTokens)
            let rhsValue = selectedMetric == .usd ? rhs.totalUsd : Double(rhs.totalTokens)
            if lhsValue == rhsValue {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    func displayedChartSeries(limit: Int = 8) -> [ChartSeriesDescriptor] {
        let series = sortedChartSeries()
        guard !selectedModels.isEmpty else { return Array(series.prefix(limit)) }

        let selected = series.filter { selectedModels.contains($0.model) }
        return selected.isEmpty ? Array(series.prefix(limit)) : selected
    }

    var hiddenChartSeriesCount: Int {
        let allCount = sortedChartSeries().count
        let visibleCount = displayedChartSeries().count
        return max(0, allCount - visibleCount)
    }

    var chartSelectableModels: [String] {
        sortedChartSeries().map(\.model)
    }

    func timelineFromSeries(_ series: ModelTimelineSeries?) -> [CostTimelinePoint] {
        guard let series else { return [] }
        return selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
    }

    func modelSparklineValues(_ model: String) -> [Double] {
        guard let series = costSummary?.modelTimelines?.first(where: { $0.model == model }) else { return [] }
        let points = selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
        return points.map { selectedMetric == .usd ? $0.usd : Double($0.tokens) }
    }

    func modelColor(for model: String) -> Color {
        let palette: [Color] = [.orange, .blue, .purple, .green, .pink, .cyan, .mint, .indigo, .teal, .red]
        return palette[stablePaletteIndex(for: model, paletteCount: palette.count)]
    }

    func distributionShare(for model: ModelCostBreakdown) -> Double {
        guard distributionMetric == .tokens else { return model.percentage }

        let totalTokens = rankedDistributionModels.reduce(0) { $0 + $1.totalTokens }
        guard totalTokens > 0 else { return 0 }
        return Double(model.totalTokens) / Double(totalTokens) * 100
    }

    func shortModelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20250514", with: "")
    }

    func chartCurrencyLabel(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 1 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.1f", value) }
        return String(format: "$%.0f", value)
    }
}
