import SwiftUI
import Charts

extension CostTrackingView {

    private var maxVisibleChartModels: Int { 8 }

    var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Spend Trend", "消费趋势"))
                    .font(.headline.weight(.bold))

                Spacer()

                modelFilterMenu

                Picker("", selection: $selectedMetric) {
                    Text("USD").tag(CostMetric.usd)
                    Text("Tokens").tag(CostMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("", selection: $selectedGranularity) {
                    Text(L("Hourly", "小时")).tag(CostGranularity.hourly)
                    Text(L("Daily", "每日")).tag(CostGranularity.daily)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            spendChart
                .frame(height: 220)

            chartLegendSection
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    var modelFilterMenu: some View {
        Menu {
            Button(action: { selectedModels = [] }) {
                HStack {
                    Text(L("All Models (Combined)", "全部模型（合计）"))
                    if selectedModels.isEmpty {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(chartSelectableModels, id: \.self) { model in
                Button(action: { toggleModelSelection(model) }) {
                    HStack {
                        Text(model)
                        if selectedModels.contains(model) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !selectedModels.isEmpty {
                Divider()
                Button(action: { selectedModels = [] }) {
                    Text(L("Clear Selection", "清除选择"))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(modelFilterLabel)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selectedModels.isEmpty ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    var modelFilterLabel: String {
        if selectedModels.isEmpty { return L("All Models", "全部模型") }
        if selectedModels.count == 1, let only = selectedModels.first {
            return shortModelName(only)
        }
        return "\(selectedModels.count) " + L("models", "个模型")
    }

    func toggleModelSelection(_ model: String) {
        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else {
            selectedModels.insert(model)
        }
    }

    @ViewBuilder
    var spendChart: some View {
        let series = displayedChartSeries(limit: maxVisibleChartModels)
        if selectedModels.isEmpty {
            let points = aggregateChartPoints()
            if points.isEmpty {
                Text(L("No data", "暂无数据"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if series.count > 1 {
                multiModelChart
            } else {
                singleSeriesChart(points: points)
            }
        } else if selectedModels.count == 1, let onlyModel = selectedModels.first {
            let points = chartPointsForModel(onlyModel)
            if points.isEmpty {
                Text(L("No data", "暂无数据"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                singleSeriesChart(points: points)
            }
        } else {
            multiModelChartFiltered
        }
    }

    var multiModelChart: some View {
        multiModelChartFor(displayedChartSeries(limit: maxVisibleChartModels))
    }

    var multiModelChartFiltered: some View {
        multiModelChartFor(displayedChartSeries(limit: maxVisibleChartModels))
    }

    func multiModelChartFor(_ allSeries: [ChartSeriesDescriptor]) -> some View {
        Chart {
            ForEach(allSeries, id: \.model) { series in
                ForEach(series.points, id: \.bucket) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", selectedMetric == .usd ? point.usd : Double(point.tokens)),
                        series: .value("Model", series.model)
                    )
                    .foregroundStyle(modelColor(for: series.model))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis { costChartXAxis }
        .chartYAxis { costChartYAxis }
    }

    @ViewBuilder
    var chartLegendSection: some View {
        let series = displayedChartSeries(limit: maxVisibleChartModels)
        if series.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                if hiddenChartSeriesCount > 0 && selectedModels.isEmpty {
                    Text(
                        L(
                            "Showing Top \(series.count) models by current metric",
                            "按当前指标仅显示前 \(series.count) 个模型"
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(series, id: \.model) { series in
                        StatsLegendChip(
                            color: modelColor(for: series.model),
                            title: series.model,
                            value: selectedMetric == .usd
                                ? formatCurrency(series.totalUsd)
                                : formatCompactNumber(Double(series.totalTokens))
                        )
                        .help(series.model)
                    }
                }
            }
        }
    }

    func singleSeriesChart(points: [CostTimelinePoint]) -> some View {
        let tint: Color = selectedMetric == .usd ? .orange : .purple
        return Chart {
            ForEach(points, id: \.bucket) { point in
                let val = selectedMetric == .usd ? point.usd : Double(point.tokens)
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Value", val)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.25), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", val)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
        .chartXAxis { costChartXAxis }
        .chartYAxis { costChartYAxis }
    }

    // MARK: - Shared Axis Builders

    @AxisContentBuilder
    var costChartXAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: selectedGranularity == .hourly ? 6 : 7)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.15))
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date, format: selectedGranularity == .hourly
                         ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                         : .dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.caption2)
                }
            }
        }
    }

    @AxisContentBuilder
    var costChartYAxis: some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.15))
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(selectedMetric == .usd ? chartCurrencyLabel(v) : formatCompactNumber(v))
                        .font(.caption2)
                }
            }
        }
    }
}
