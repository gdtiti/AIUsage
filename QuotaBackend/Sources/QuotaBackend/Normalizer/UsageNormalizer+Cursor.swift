import Foundation

extension UsageNormalizer {

    // MARK: - Cursor

    static func normalizeCursor(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "Main Plan", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Auto / Composer", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Named Models", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let membershipType = membershipBadge(from: usage.accountPlan ?? extraString(usage, "membershipType")) ?? "Subscription"
        let billingReset = extraString(usage, "billingCycleResetDescription") ?? "Billing cycle detected"
        let billingEnd = extraString(usage, "billingCycleEnd")

        let includedUsed = extraDouble(usage, "includedPlan.usedUsd")
        let includedLimit = extraDouble(usage, "includedPlan.limitUsd")
        let onDemandUsed = extraDouble(usage, "onDemand.usedUsd")

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: membershipType)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = billingEnd
        base.nextResetLabel = formatShortDateTime(billingEnd)
        base.headline = HeadlineInfo(
            eyebrow: "Membership · \(membershipType)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Cursor usage snapshot" : "tightest remaining allowance",
            supporting: billingReset
        )
        base.metrics = [
            MetricInfo(label: "Account",      value: usage.accountEmail ?? usage.accountName ?? "Unknown"),
            MetricInfo(
                label: "Included Plan",
                value: {
                    if let includedUsed, let includedLimit {
                        return "\(formatCurrency(includedUsed)) / \(formatCurrency(includedLimit))"
                    }
                    return "Not available"
                }()
            ),
            MetricInfo(label: "On-demand",    value: onDemandUsed.map { "\(formatCurrency($0)) used" } ?? "Not available"),
            MetricInfo(label: "Source",       value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Cursor mixes percent-based allowances with dollar-based plan spend, so the card pairs remaining percentages with included and on-demand spend signals."
        return base
    }
}
