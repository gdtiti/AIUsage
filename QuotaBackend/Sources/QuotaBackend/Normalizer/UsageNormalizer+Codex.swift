import Foundation

extension UsageNormalizer {

    // MARK: - Codex

    static func normalizeCodex(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "5h Window", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Weekly Window", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Code Review", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan.map { titleCase($0) } ?? "Unknown"

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = usage.primary?.resetAt ?? usage.secondary?.resetAt
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Usage snapshot ready" : "lowest remaining window",
            supporting: usage.accountEmail ?? "OpenAI account"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Plan",    value: plan),
            MetricInfo(label: "Source",  value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting."
        return base
    }
}
