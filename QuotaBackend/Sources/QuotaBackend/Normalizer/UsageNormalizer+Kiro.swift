import Foundation

extension UsageNormalizer {

    // MARK: - Kiro

    static func normalizeKiro(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let rawWindows = [usage.primary, usage.secondary, usage.tertiary].compactMap { $0 }
        let windows = rawWindows.map { window in
            createPercentWindow(label: window.label ?? "Usage Lane", window: window)
        }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Standard"
        let authProvider = extraString(usage, "authProvider")
        let authMethod = formatKiroAuthMethod(extraString(usage, "authMethod"))
        let region = extraString(usage, "region") ?? "us-east-1"
        let tokenExpiresAt = extraString(usage, "tokenExpiresAt")
        let quotaEntryCount = extraInt(usage, "quotaEntryCount") ?? windows.count
        let hiddenQuotaCount = extraInt(usage, "hiddenQuotaCount") ?? 0

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = rawWindows.compactMap { $0.resetAt }.compactMap(parseDate).min().map { SharedFormatters.iso8601String(from: $0) }
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Kiro usage snapshot" : "tightest Kiro lane",
            supporting: usage.accountEmail ?? usage.accountName ?? authProvider.map { "Kiro \($0)" } ?? "Kiro account"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? usage.accountName ?? "Unknown"),
            MetricInfo(label: "Auth", value: joinParts([authProvider, authMethod]) ?? authMethod ?? "Unknown"),
            MetricInfo(label: "Region", value: region, note: tokenExpiresAt.flatMap { formatShortDateTime($0) }.map { "token expires \($0)" }),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source), note: "\(formatInt(quotaEntryCount)) lanes tracked")
        ]
        base.windows = windows
        base.spotlight = hiddenQuotaCount > 0
            ? "Kiro reported \(formatInt(quotaEntryCount)) usage lanes. This card shows the three tightest ones first so attention stays on the lanes that will run out soonest."
            : "Kiro usage is pulled from the same AWS-backed endpoint the desktop app uses, so this snapshot reflects the live agentic request lanes exposed by the app."
        return base
    }
}
