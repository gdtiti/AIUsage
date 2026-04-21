import SwiftUI

// MARK: - Claude Code Usage Heatmap

struct ClaudeCodeUsageHeatmap: View {
    let providers: [ProviderData]

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private let weeks = 52

    // MARK: - Data

    private var dailyTokens: [Date: Int] {
        let calendar = Calendar.current
        var map: [Date: Int] = [:]
        for provider in providers {
            guard let daily = provider.costSummary?.timeline?.daily else { continue }
            for point in daily where point.tokens > 0 {
                let day = calendar.startOfDay(for: point.date)
                map[day, default: 0] += point.tokens
            }
        }
        return map
    }

    private var startDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1=Sun, 7=Sat
        let daysFromSunday = weekday - 1
        let currentWeekStart = calendar.date(byAdding: .day, value: -daysFromSunday, to: today) ?? today
        return calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: currentWeekStart) ?? today
    }

    private func date(forWeek week: Int, day: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: week * 7 + day, to: startDate) ?? .distantPast
    }

    private var thresholds: [Int] {
        let values = dailyTokens.values.filter { $0 > 0 }.sorted()
        guard values.count >= 2 else {
            return values.isEmpty ? [] : [values[0], values[0], values[0]]
        }
        func percentile(_ p: Double) -> Int {
            let idx = Int((Double(values.count) - 1) * p)
            return values[max(0, min(values.count - 1, idx))]
        }
        return [percentile(0.25), percentile(0.50), percentile(0.75)]
    }

    private func bin(for tokens: Int, thresholds: [Int]) -> Int {
        guard tokens > 0 else { return 0 }
        guard thresholds.count == 3 else { return 1 }
        if tokens <= thresholds[0] { return 1 }
        if tokens <= thresholds[1] { return 2 }
        if tokens <= thresholds[2] { return 3 }
        return 4
    }

    private static let heatmapAccent = Color.green

    private func color(for bin: Int, active: Bool) -> Color {
        guard active else { return Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03) }
        let accent = Self.heatmapAccent
        switch bin {
        case 0: return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
        case 1: return accent.opacity(colorScheme == .dark ? 0.32 : 0.26)
        case 2: return accent.opacity(colorScheme == .dark ? 0.54 : 0.46)
        case 3: return accent.opacity(colorScheme == .dark ? 0.76 : 0.68)
        case 4: return accent.opacity(colorScheme == .dark ? 0.96 : 0.90)
        default: return Color.clear
        }
    }

    private var totalTokens: Int {
        dailyTokens.values.reduce(0, +)
    }

    private var activeDayCount: Int {
        dailyTokens.values.filter { $0 > 0 }.count
    }

    private var maxDayTokens: (date: Date, tokens: Int)? {
        dailyTokens.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if dailyTokens.isEmpty {
                emptyState
            } else {
                gridSection
                footer
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Claude Code Usage Heatmap", "Claude Code 使用热力图"))
                .font(.headline.weight(.bold))
            Text(L("Daily token volume", "每日 Token 总量"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid

    private var gridSection: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let weekdayLabelWidth: CGFloat = 28
            let monthLabelHeight: CGFloat = 14
            let availableWidth = max(0, proxy.size.width - weekdayLabelWidth)
            let cellSide = max(8, min(16, (availableWidth - CGFloat(weeks - 1) * spacing) / CGFloat(weeks)))
            let columnPitch = cellSide + spacing
            let gridHeight = cellSide * 7 + spacing * 6

            VStack(alignment: .leading, spacing: 4) {
                monthLabelsRow(cellSide: cellSide, columnPitch: columnPitch, height: monthLabelHeight)
                    .frame(height: monthLabelHeight)

                HStack(alignment: .top, spacing: 0) {
                    weekdayLabels(cellSide: cellSide, spacing: spacing)
                        .frame(width: weekdayLabelWidth, height: gridHeight, alignment: .topLeading)

                    gridColumns(cellSide: cellSide, spacing: spacing)
                }
            }
        }
        .frame(height: 170)
    }

    private func monthLabelsRow(cellSide: CGFloat, columnPitch: CGFloat, height: CGFloat) -> some View {
        let weekdayLabelWidth: CGFloat = 28
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appState.language == "zh" ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = appState.language == "zh" ? "M月" : "MMM"

        let calendar = Calendar.current
        var labels: [(column: Int, text: String)] = []
        var previousMonth = -1
        for week in 0..<weeks {
            let day = date(forWeek: week, day: 0)
            let month = calendar.component(.month, from: day)
            if month != previousMonth {
                labels.append((week, formatter.string(from: day)))
                previousMonth = month
            }
        }

        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(labels, id: \.column) { entry in
                Text(entry.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: weekdayLabelWidth + CGFloat(entry.column) * columnPitch, y: 0)
            }
        }
    }

    private func weekdayLabels(cellSide: CGFloat, spacing: CGFloat) -> some View {
        let visibleRows: Set<Int> = [1, 3, 5] // Mon, Wed, Fri
        let names: [String] = [
            L("Sun", "日"),
            L("Mon", "一"),
            L("Tue", "二"),
            L("Wed", "三"),
            L("Thu", "四"),
            L("Fri", "五"),
            L("Sat", "六")
        ]
        return VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: cellSide)
                    if visibleRows.contains(row) {
                        Text(names[row])
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func gridColumns(cellSide: CGFloat, spacing: CGFloat) -> some View {
        let tokens = dailyTokens
        let computedThresholds = thresholds
        let today = Calendar.current.startOfDay(for: Date())
        let accent = Self.heatmapAccent

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { day in
                        let cellDate = date(forWeek: week, day: day)
                        let isActive = cellDate <= today
                        let count = isActive ? (tokens[cellDate] ?? 0) : 0
                        let binIndex = bin(for: count, thresholds: computedThresholds)
                        let isToday = isActive && cellDate == today

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: binIndex, active: isActive))
                            .frame(width: cellSide, height: cellSide)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(isToday ? accent.opacity(0.9) : Color.clear,
                                            lineWidth: isToday ? 1 : 0)
                            )
                            .help(tooltipText(for: cellDate, tokens: count, isActive: isActive))
                    }
                }
            }
        }
    }

    private func tooltipText(for date: Date, tokens: Int, isActive: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appState.language == "zh" ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = appState.language == "zh" ? "yyyy年M月d日" : "MMM d, yyyy"
        let dateLabel = formatter.string(from: date)

        guard isActive else {
            return dateLabel + " · " + L("Not yet", "尚未到达")
        }

        if tokens > 0 {
            return dateLabel + " · " + L("\(formatNumber(tokens)) tokens", "\(formatNumber(tokens)) tokens")
        }
        return dateLabel + " · " + L("No activity", "无使用记录")
    }

    private func peakSummaryText(for peak: (date: Date, tokens: Int)) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appState.language == "zh" ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = appState.language == "zh" ? "M月d日" : "MMM d"
        let peakDate = formatter.string(from: peak.date)
        let peakValue = formatCompactNumber(Double(peak.tokens))
        return L(
            "\(activeDayCount) active days · peak \(peakValue) on \(peakDate)",
            "活跃 \(activeDayCount) 天 · 最高 \(peakValue) 于 \(peakDate)"
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Total \(formatCompactNumber(Double(totalTokens))) tokens",
                       "合计 \(formatCompactNumber(Double(totalTokens))) tokens"))
                    .font(.caption.weight(.semibold))
                if let peak = maxDayTokens {
                    Text(peakSummaryText(for: peak))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Text(L("Less", "少"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: level, active: true))
                        .frame(width: 10, height: 10)
                }
                Text(L("More", "多"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("No usage recorded yet", "暂无使用记录"))
                    .font(.subheadline.weight(.semibold))
                Text(L("Claude Code daily token data will appear here once logs are imported.",
                       "当 Claude Code 日志被导入后，这里将显示每日 Token 数据。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}
