import SwiftUI
import QuotaBackend

struct ResetCountdownView: View {
    let resetAt: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    private var resetDate: Date? {
        Self.parseISO8601(resetAt)
    }

    var body: some View {
        if let resetDate {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let snapshot = countdownSnapshot(to: resetDate, now: context.date)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(L("Next reset", "下次刷新"), systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(accentColor)

                        Spacer()

                        Text(absoluteResetText(resetDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        CountdownUnitView(value: snapshot.days, unit: L("D", "天"), accentColor: accentColor, emphasized: snapshot.days > 0)
                        CountdownUnitView(value: snapshot.hours, unit: L("H", "时"), accentColor: accentColor, emphasized: snapshot.days == 0 && snapshot.hours > 0)
                        CountdownUnitView(value: snapshot.minutes, unit: L("M", "分"), accentColor: accentColor, emphasized: snapshot.days == 0 && snapshot.hours == 0)

                        Spacer(minLength: 8)

                        Text(snapshot.primaryLabel(language: appState.language))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(snapshot.highlightColor)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(backgroundGradient)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(borderColor(for: snapshot), lineWidth: 1)
                )
            }
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10),
                Color.white.opacity(colorScheme == .dark ? 0.02 : 0.45)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func borderColor(for snapshot: CountdownSnapshot) -> Color {
        snapshot.highlightColor.opacity(colorScheme == .dark ? 0.34 : 0.18)
    }

    private func absoluteResetText(_ date: Date) -> String {
        let locale = Locale(identifier: appState.language == "zh" ? "zh_CN" : "en_US")
        let format = appState.language == "zh" ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return DateFormat.formatter(format, timeZone: .current, locale: locale).string(from: date)
    }

    private func countdownSnapshot(to target: Date, now: Date) -> CountdownSnapshot {
        let remaining = max(0, Int(target.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = max(0, (remaining % 3_600) / 60)
        return CountdownSnapshot(days: days, hours: hours, minutes: minutes, totalSeconds: remaining)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }
}

struct CountdownUnitView: View {
    let value: Int
    let unit: String
    let accentColor: Color
    let emphasized: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", value))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasized ? Color.primary : .primary.opacity(0.9))

            Text(unit)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 46)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tileBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tileBorder, lineWidth: 1)
        )
    }

    private var tileBackground: Color {
        if emphasized {
            return accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
        return colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55)
    }

    private var tileBorder: Color {
        if emphasized {
            return accentColor.opacity(colorScheme == .dark ? 0.40 : 0.2)
        }
        return colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
}

struct CountdownSnapshot {
    let days: Int
    let hours: Int
    let minutes: Int
    let totalSeconds: Int

    var highlightColor: Color {
        switch totalSeconds {
        case ..<3_600:
            return .red
        case ..<21_600:
            return .orange
        default:
            return .green
        }
    }

    func primaryLabel(language: String) -> String {
        if totalSeconds == 0 {
            return language == "zh" ? "即将刷新" : "Refreshing soon"
        }
        if days > 0 {
            return language == "zh" ? "\(days)天 \(hours)小时" : "\(days)d \(hours)h"
        }
        if hours > 0 {
            return language == "zh" ? "\(hours)小时 \(minutes)分钟" : "\(hours)h \(minutes)m"
        }
        return language == "zh" ? "\(max(1, minutes))分钟内" : "within \(max(1, minutes))m"
    }
}
