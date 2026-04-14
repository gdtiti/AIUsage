import SwiftUI
import Charts

extension CostTrackingView {

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
            ForEach(models) { model in
                Button(action: { toggleModelSelection(model.model) }) {
                    HStack {
                        Text(shortModelName(model.model))
                        if selectedModels.contains(model.model) {
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
        let series = chartModelSeries()
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
        multiModelChartFor(chartModelSeries())
    }

    var multiModelChartFiltered: some View {
        multiModelChartFor(chartModelSeries().filter { selectedModels.contains($0.model) })
    }

    func multiModelChartFor(_ allSeries: [(model: String, points: [CostTimelinePoint])]) -> some View {
        Chart {
            ForEach(allSeries, id: \.model) { series in
                ForEach(series.points, id: \.bucket) { point in
                    LineMark(
                        x: .value("Time", point.label),
                        y: .value("Value", selectedMetric == .usd ? point.usd : Double(point.tokens))
                    )
                    .foregroundStyle(by: .value("Model", shortModelName(series.model)))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: selectedGranularity == .hourly ? 6 : 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .chartYAxis {
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

    func singleSeriesChart(points: [CostTimelinePoint]) -> some View {
        let tint: Color = selectedMetric == .usd ? .orange : .purple
        return Chart {
            ForEach(points, id: \.bucket) { point in
                let val = selectedMetric == .usd ? point.usd : Double(point.tokens)
                AreaMark(
                    x: .value("Time", point.label),
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
                    x: .value("Time", point.label),
                    y: .value("Value", val)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: selectedGranularity == .hourly ? 6 : 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .chartYAxis {
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
}
