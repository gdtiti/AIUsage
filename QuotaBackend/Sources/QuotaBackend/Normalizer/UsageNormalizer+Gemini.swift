import Foundation

extension UsageNormalizer {

    // MARK: - Gemini

    static func normalizeGemini(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "Pro", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Flash", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Flash Lite", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Unknown"
        let projectId = extraString(usage, "projectId")
        let lowestPercentLeft = extraDouble(usage, "lowestPercentLeft")

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
            secondary: remainingPercent == nil ? "Gemini quota snapshot" : "lowest remaining family",
            supporting: usage.accountEmail ?? projectId ?? "Gemini CLI account"
        )
        base.metrics = [
            MetricInfo(label: "Account",          value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Project",           value: projectId ?? "Unknown"),
            MetricInfo(label: "Lowest Remaining",  value: lowestPercentLeft.map { formatPercent($0) } ?? "Unknown"),
            MetricInfo(label: "Source",            value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Gemini quota is model-family based, so the dashboard groups the lowest remaining family first and keeps the project context attached."
        return base
    }
}
