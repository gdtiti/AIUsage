import Foundation

extension UsageNormalizer {

    // MARK: - Warp

    static func normalizeWarp(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        base.accountLabel = preferredAccountEmail(usage)

        let requestsRemaining = extra(usage, "requestsRemaining") as? Int
        let requestLimit = extra(usage, "requestLimit") as? Int
        let requestsUsed = extra(usage, "requestsUsed") as? Int
        let assistantRequestsUsed = extra(usage, "assistantRequestsUsed") as? Int
        let bonusCreditsRemaining = extra(usage, "bonusCreditsRemaining") as? Int
        let bonusCreditsTotal = extra(usage, "bonusCreditsTotal") as? Int
        let isUnlimited = extra(usage, "isUnlimited") as? Bool ?? false

        var windows: [WindowInfo] = []
        if let w = usage.primary { windows.append(createQuotaWindow(label: "Requests", window: w)) }
        if let w = usage.secondary { windows.append(createQuotaWindow(label: "Assistant Credits", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)

        let primaryText: String
        if let rem = requestsRemaining, let lim = requestLimit {
            primaryText = "\(formatInt(rem)) / \(formatInt(lim))"
        } else {
            primaryText = remainingPercent.map { formatPercent($0) } ?? "Connected"
        }

        let supporting: String
        if let bonus = bonusCreditsRemaining {
            supporting = "\(formatInt(bonus)) bonus credits remain"
        } else {
            supporting = formatSourceLabel(usage.source)
        }

        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = usage.primary?.resetAt ?? usage.secondary?.resetAt
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: isUnlimited ? "Unlimited mode" : "Desktop quota cache",
            primary: primaryText,
            secondary: requestsRemaining != nil && requestLimit != nil ? "main request reserve" : "quota snapshot",
            supporting: supporting
        )
        base.metrics = [
            MetricInfo(label: "Main Pool", value: "\(formatInt(requestsUsed ?? 0)) used"),
            MetricInfo(label: "Assistant Pool", value: assistantRequestsUsed.map { "\(formatInt($0)) used" } ?? "Not available"),
            MetricInfo(label: "Bonus Credits", value: bonusCreditsRemaining.map { "\(formatInt($0)) / \(formatInt(bonusCreditsTotal ?? 0))" } ?? "None"),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Warp can read from local app cache, which makes the panel feel instantaneous and keeps the design centered on what is actually left right now."
        return base
    }
}
