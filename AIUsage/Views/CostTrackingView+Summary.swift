import SwiftUI
import Charts

extension CostTrackingView {

    var logDateRange: String? {
        guard let timeline = costSummary?.timeline else { return nil }
        let points = !timeline.daily.isEmpty ? timeline.daily : timeline.hourly
        guard let first = points.first?.bucket, let last = points.last?.bucket else { return nil }
        return "\(first) – \(last)"
    }

    var logDayCount: Int {
        guard let timeline = costSummary?.timeline else { return 0 }
        let points = !timeline.daily.isEmpty ? timeline.daily : timeline.hourly
        return max(1, points.count)
    }

    /// Cache hit rate across all tracked models: cache_read / (input + cache_read + cache_creation).
    /// Returns nil when no cache-eligible traffic has been observed yet (to display an em-dash instead of 0%).
    var overallCacheHitRate: Double? {
        guard let breakdowns = costSummary?.modelBreakdownOverall ?? costSummary?.modelBreakdown,
              !breakdowns.isEmpty else { return nil }
        var read = 0
        var write = 0
        var input = 0
        for b in breakdowns {
            read += b.cacheReadTokens
            write += b.cacheCreateTokens
            input += b.inputTokens
        }
        let denom = input + read + write
        guard denom > 0 else { return nil }
        return Double(read) / Double(denom) * 100
    }

    var summaryStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                summaryCell(
                    icon: "chart.bar.fill",
                    title: L("Overall", "总计"),
                    value: formatCurrency(costSummary?.overall?.usd ?? 0),
                    tint: .red
                )
                summaryCell(
                    icon: "dollarsign.circle.fill",
                    title: L("This Month", "本月"),
                    value: formatCurrency(costSummary?.month?.usd ?? 0),
                    tint: .orange
                )
                summaryCell(
                    icon: "calendar",
                    title: L("This Week", "本周"),
                    value: formatCurrency(costSummary?.week?.usd ?? 0),
                    tint: .blue
                )
                summaryCell(
                    icon: "sun.max.fill",
                    title: L("Today", "今天"),
                    value: formatCurrency(costSummary?.today?.usd ?? 0),
                    tint: .green
                )
                summaryCell(
                    icon: "bolt.fill",
                    title: L("Total Tokens", "总 Tokens"),
                    value: formatCompactNumber(Double(costSummary?.overall?.tokens ?? 0)),
                    tint: .purple
                )
                summaryCell(
                    icon: "scope",
                    title: L("Cache Hit Rate", "缓存命中率"),
                    value: overallCacheHitRate.map { String(format: "%.1f%%", $0) } ?? "—",
                    tint: .teal
                )
                summaryCell(
                    icon: "cpu",
                    title: L("Models", "模型数"),
                    value: "\(models.count)",
                    tint: .pink
                )
            }

            if let range = logDateRange {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L("Based on local JSONL logs (\(range)). Claude Code retains ~7 days of logs; \"Overall\" reflects available data only.",
                           "基于本地 JSONL 日志（\(range)）。Claude Code 仅保留约 7 天日志，「总计」仅反映现有数据。"))
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

    func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
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
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
