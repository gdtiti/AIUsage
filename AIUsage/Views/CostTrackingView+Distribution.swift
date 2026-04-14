import SwiftUI
import Charts

extension CostTrackingView {

    var distributionModels: [ModelCostBreakdown] {
        switch distributionPeriod {
        case .today: return costSummary?.modelBreakdownToday ?? []
        case .week: return costSummary?.modelBreakdownWeek ?? []
        case .month: return costSummary?.modelBreakdown ?? []
        case .overall: return costSummary?.modelBreakdownOverall ?? []
        }
    }

    var modelDistribution: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Model Distribution", "模型分布"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            HStack(spacing: 8) {
                Picker("", selection: $distributionPeriod) {
                    Text(L("Today", "今日")).tag(DistributionPeriod.today)
                    Text(L("Week", "本周")).tag(DistributionPeriod.week)
                    Text(L("Month", "本月")).tag(DistributionPeriod.month)
                    Text(L("All", "全部")).tag(DistributionPeriod.overall)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                Picker("", selection: $distributionMetric) {
                    Text("USD").tag(CostMetric.usd)
                    Text("Tokens").tag(CostMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            let distModels = distributionModels
            if distModels.isEmpty {
                Text(L("No data for this period", "该时段暂无数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                donutChart
                    .frame(height: 200)

                VStack(spacing: 6) {
                    ForEach(Array(distModels.prefix(6).enumerated()), id: \.element.id) { index, model in
                        let color = modelColor(index)
                        HStack(spacing: 8) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(shortModelName(model.model))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            if distributionMetric == .usd {
                                Text(formatCurrency(model.estimatedCostUsd))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                Text(String(format: "%.1f%%", model.percentage))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(formatCompactNumber(Double(model.totalTokens)))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                let totalTokens = distModels.reduce(0) { $0 + $1.totalTokens }
                                let pct = totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0
                                Text(String(format: "%.1f%%", pct))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    var donutChart: some View {
        let items = Array(distributionModels.prefix(6))
        let totalTokens = distributionModels.reduce(0) { $0 + $1.totalTokens }
        return Chart(Array(items.enumerated()), id: \.element.id) { index, model in
            SectorMark(
                angle: .value("Value", max(donutValue(model), 0.001)),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .foregroundStyle(modelColor(index))
            .cornerRadius(4)
            .annotation(position: .overlay) {
                let pct = distributionMetric == .usd ? model.percentage :
                    (totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0)
                if pct >= 10 {
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .chartLegend(.hidden)
    }

    func donutValue(_ model: ModelCostBreakdown) -> Double {
        distributionMetric == .usd ? model.estimatedCostUsd : Double(model.totalTokens)
    }
}
