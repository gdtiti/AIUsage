import SwiftUI

// MARK: - Claude Code Usage Heatmap

struct ClaudeCodeUsageHeatmap: View {
    let providers: [ProviderData]

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoveredCell: HeatmapCellID?

    private let weeks = 52
    private static let tooltipWidth: CGFloat = 280

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

    private var dailyUsd: [Date: Double] {
        let calendar = Calendar.current
        var map: [Date: Double] = [:]
        for provider in providers {
            guard let daily = provider.costSummary?.timeline?.daily else { continue }
            for point in daily {
                let day = calendar.startOfDay(for: point.date)
                map[day, default: 0] += point.usd
            }
        }
        return map
    }

    private func modelBreakdown(for targetDate: Date) -> [(model: String, tokens: Int, usd: Double)] {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: targetDate)
        var result: [(String, Int, Double)] = []
        for provider in providers {
            guard let timelines = provider.costSummary?.modelTimelines else { continue }
            for series in timelines {
                for point in series.daily {
                    if calendar.startOfDay(for: point.date) == targetDay, point.tokens > 0 {
                        result.append((series.model, point.tokens, point.usd))
                    }
                }
            }
        }
        return result.sorted { $0.1 > $1.1 }
    }

    private var startDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
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
                    .zIndex(1)
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
            .overlay {
                if let hovered = hoveredCell {
                    heatmapTooltipOverlay(
                        cell: hovered,
                        cellSide: cellSide,
                        spacing: spacing,
                        columnPitch: columnPitch,
                        weekdayLabelWidth: weekdayLabelWidth,
                        monthLabelHeight: monthLabelHeight,
                        containerWidth: proxy.size.width
                    )
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
        let visibleRows: Set<Int> = [1, 3, 5]
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
                        let isHovered = hoveredCell?.week == week && hoveredCell?.day == day

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: binIndex, active: isActive))
                            .frame(width: cellSide, height: cellSide)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(
                                        isHovered ? accent : (isToday ? accent.opacity(0.9) : Color.clear),
                                        lineWidth: isHovered ? 1.5 : (isToday ? 1 : 0)
                                    )
                            )
                            .scaleEffect(isHovered ? 1.3 : 1.0)
                            .zIndex(isHovered ? 10 : 0)
                            .animation(.easeOut(duration: 0.12), value: isHovered)
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    hoveredCell = hovering ? HeatmapCellID(week: week, day: day) : nil
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: - Tooltip Overlay

    @ViewBuilder
    private func heatmapTooltipOverlay(
        cell: HeatmapCellID,
        cellSide: CGFloat,
        spacing: CGFloat,
        columnPitch: CGFloat,
        weekdayLabelWidth: CGFloat,
        monthLabelHeight: CGFloat,
        containerWidth: CGFloat
    ) -> some View {
        let cellDate = date(forWeek: cell.week, day: cell.day)
        let today = Calendar.current.startOfDay(for: Date())
        let isActive = cellDate <= today
        let tokens = isActive ? (dailyTokens[cellDate] ?? 0) : 0
        let usd = isActive ? (dailyUsd[cellDate] ?? 0) : 0
        let models = (isActive && tokens > 0) ? modelBreakdown(for: cellDate) : []

        let cellCenterX = weekdayLabelWidth + CGFloat(cell.week) * columnPitch + cellSide / 2
        let gridTopY = monthLabelHeight + 4
        let cellBottomY = gridTopY + CGFloat(cell.day) * (cellSide + spacing) + cellSide

        let tw = Self.tooltipWidth
        let xClamped = max(4, min(containerWidth - tw - 4, cellCenterX - tw / 2))

        heatmapTooltipCard(
            date: cellDate,
            isActive: isActive,
            tokens: tokens,
            usd: usd,
            models: models
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: tw, alignment: .topLeading)
        .offset(x: xClamped, y: cellBottomY + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func heatmapTooltipCard(
        date: Date,
        isActive: Bool,
        tokens: Int,
        usd: Double,
        models: [(model: String, tokens: Int, usd: Double)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tooltipDateHeader(date: date, isActive: isActive)

            if isActive {
                tooltipMetrics(tokens: tokens, usd: usd)

                if !models.isEmpty {
                    Divider()
                        .padding(.vertical, 6)

                    tooltipModelList(models: models)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.6 : 0.18), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.5)
        )
    }

    private func tooltipDateHeader(date: Date, isActive: Bool) -> some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appState.language == "zh" ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = appState.language == "zh" ? "yyyy年M月d日 EEE" : "EEE, MMM d, yyyy"
        let dateStr = formatter.string(from: date)

        return HStack(spacing: 4) {
            Text(dateStr)
                .font(.caption.weight(.semibold))
            Spacer()
            if !isActive {
                Text(L("Future", "尚未到达"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, isActive ? 6 : 0)
    }

    private func tooltipMetrics(tokens: Int, usd: Double) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Tokens", "Tokens"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(formatNumber(tokens))
                    .font(.caption.weight(.medium).monospacedDigit())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(L("Cost", "费用"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(formatCurrency(usd))
                    .font(.caption.weight(.medium).monospacedDigit())
            }
        }
    }

    private func tooltipModelList(models: [(model: String, tokens: Int, usd: Double)]) -> some View {
        let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal, .yellow, .red]

        return VStack(alignment: .leading, spacing: 4) {
            Text(L("Models", "模型"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            ForEach(Array(models.prefix(5).enumerated()), id: \.offset) { idx, entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(palette[idx % palette.count].opacity(0.8))
                        .frame(width: 5, height: 5)
                    Text(entry.model)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        Text(formatCompactNumber(Double(entry.tokens)))
                        Text(formatCurrency(entry.usd))
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }

            if models.count > 5 {
                Text(L("+\(models.count - 5) more", "+\(models.count - 5) 更多"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
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

    // MARK: - Helpers

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
}

// MARK: - Supporting Types

private struct HeatmapCellID: Equatable {
    let week: Int
    let day: Int
}

