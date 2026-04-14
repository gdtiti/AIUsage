import Foundation

extension UsageNormalizer {

    // MARK: - Amp

    static func normalizeAmp(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let remaining = extraInt(usage, "remaining")
        let quota = extraInt(usage, "quota")
        let hourlyReplenishment = extraInt(usage, "hourlyReplenishment")
        let estimatedFullResetAt = extraString(usage, "estimatedFullResetAt")

        let remainingPercent: Double?
        if let r = usage.primary?.remainingPercent { remainingPercent = r }
        else if let rem = remaining, let q = quota, q > 0 { remainingPercent = Double(rem) / Double(q) * 100 }
        else { remainingPercent = nil }

        var windows: [WindowInfo] = []
        if let w = usage.primary { windows.append(createQuotaWindow(label: "Free Quota", window: w)) }

        let (status, statusLabel) = resolveStatus(remainingPercent)

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: usage.accountPlan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = estimatedFullResetAt
        base.nextResetLabel = formatShortDateTime(estimatedFullResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Free tier reserve",
            primary: "\(formatInt(remaining ?? 0)) / \(formatInt(quota ?? 0))",
            secondary: remainingPercent.map { "\(formatPercent($0)) left" } ?? "Unknown",
            supporting: hourlyReplenishment.map { "Replenishes about \(formatInt($0)) units per hour" } ?? "Live browser cookie import"
        )
        base.metrics = [
            MetricInfo(label: "Used",        value: formatInt(extraInt(usage, "used") ?? 0)),
            MetricInfo(label: "Remaining",   value: formatInt(remaining ?? 0)),
            MetricInfo(label: "Hourly Refill", value: hourlyReplenishment.map { "\(formatInt($0))/h" } ?? "Unknown"),
            MetricInfo(label: "Source",      value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Amp is best viewed as a replenishing credit pool, so the card highlights remaining balance and refill cadence instead of a hard billing period."
        return base
    }
}
