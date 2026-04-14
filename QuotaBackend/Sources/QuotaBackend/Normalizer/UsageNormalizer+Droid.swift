import Foundation

extension UsageNormalizer {

    // MARK: - Droid

    static func normalizeDroid(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "Standard", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Premium", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let planName = extraString(usage, "planName") ?? "Factory usage"
        let orgName = extraString(usage, "organizationName")
        let periodEnd = extraString(usage, "periodEnd")

        let stdUserTokens = extraInt(usage, "standard.userTokens") ?? 0
        let stdTotalAllowance = extraInt(usage, "standard.totalAllowance") ?? 0
        let stdUnlimited = extra(usage, "standard.unlimited") as? Bool ?? false
        let premUserTokens = extraInt(usage, "premium.userTokens") ?? 0
        let premTotalAllowance = extraInt(usage, "premium.totalAllowance") ?? 0
        let premUnlimited = extra(usage, "premium.unlimited") as? Bool ?? false

        let periodStart = extraString(usage, "periodStart")

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: planName)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = periodEnd
        base.nextResetLabel = formatShortDateTime(periodEnd)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Token telemetry ready" : "lowest remaining token pool",
            supporting: orgName ?? usage.accountEmail ?? "Factory account"
        )
        base.metrics = [
            MetricInfo(label: "Standard Tokens", value: "\(formatInt(stdUserTokens)) / \(stdUnlimited ? "Unlimited" : formatInt(stdTotalAllowance))"),
            MetricInfo(label: "Premium Tokens",  value: "\(formatInt(premUserTokens)) / \(premUnlimited ? "Unlimited" : formatInt(premTotalAllowance))"),
            MetricInfo(label: "Billing Period",  value: formatRange(periodStart, periodEnd)),
            MetricInfo(label: "Source",          value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Droid usage is token-heavy, so the panel keeps raw token counts visible next to the percentage-based pools."
        return base
    }
}
