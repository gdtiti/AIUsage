import SwiftUI

extension CostTrackingView {

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

    func chartModelSeries() -> [(model: String, points: [CostTimelinePoint])] {
        guard let modelTimelines = costSummary?.modelTimelines else { return [] }
        return modelTimelines.compactMap { series in
            let points = timelineFromSeries(series)
            guard !points.isEmpty else { return nil }
            return (model: series.model, points: points)
        }
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

    func modelColor(_ index: Int) -> Color {
        let palette: [Color] = [.orange, .blue, .purple, .green, .pink, .cyan, .mint, .indigo, .teal, .red]
        return palette[index % palette.count]
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
