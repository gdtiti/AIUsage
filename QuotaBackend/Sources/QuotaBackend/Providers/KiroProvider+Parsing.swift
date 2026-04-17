import CryptoKit
import Foundation

// MARK: - Account Identity

extension KiroProvider {
    /// Stable accountId derived from API response (email) → token email → profileArn.
    /// Avoids using filenames which differ per auth source.
    func stableAccountId(usage: ProviderUsage, context: AuthContext) -> String {
        usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? context.tokenData.email?.nilIfBlank
            ?? context.tokenData.profileArn?.nilIfBlank
            ?? context.url.lastPathComponent
    }

    func fallbackAccountId(for context: AuthContext) -> String {
        context.tokenData.email?.nilIfBlank
            ?? context.tokenData.profileArn?.nilIfBlank
            ?? context.url.lastPathComponent
    }
}

// MARK: - Normalize Usage

extension KiroProvider {
    func buildUsage(authContext: AuthContext,
                    tokenData: KiroTokenData,
                    response: KiroUsageResponse) -> ProviderUsage {
        let entries = buildEntries(from: response)
        let sortedEntries = entries.sorted { lhs, rhs in
            lhs.remainingPercent < rhs.remainingPercent
        }

        var usage = ProviderUsage(provider: "kiro", label: "Kiro")
        usage.accountEmail = response.userInfo?.email
            ?? emailLike(response.userInfo?.userId)
            ?? tokenData.email
        usage.accountName = response.userInfo?.userId ?? tokenData.authProvider.map { "Kiro (\($0))" }
        usage.accountPlan = response.subscriptionInfo?.subscriptionTitle ?? response.subscriptionInfo?.type ?? "Standard"

        let topEntries = Array(sortedEntries.prefix(3))
        if topEntries.indices.contains(0) { usage.primary = createWindow(from: topEntries[0]) }
        if topEntries.indices.contains(1) { usage.secondary = createWindow(from: topEntries[1]) }
        if topEntries.indices.contains(2) { usage.tertiary = createWindow(from: topEntries[2]) }

        var source = SourceInfo(mode: "oauth", type: authContext.sourceType)
        source.profile = authContext.url.lastPathComponent
        source.roots = [authContext.sourceDirectory]
        usage.source = source

        usage.extra["authMethod"] = AnyCodable(tokenData.authMethod)
        usage.extra["authProvider"] = AnyCodable(tokenData.authProvider ?? "")
        usage.extra["region"] = AnyCodable(tokenData.region)
        usage.extra["profileArn"] = AnyCodable(tokenData.profileArn ?? "")
        usage.extra["selectedAuthFile"] = AnyCodable(authContext.url.lastPathComponent)
        usage.extra["authFileCount"] = AnyCodable(authContext.fileCount)
        usage.extra["quotaEntryCount"] = AnyCodable(entries.count)
        usage.extra["hiddenQuotaCount"] = AnyCodable(max(0, entries.count - topEntries.count))
        usage.extra["tokenExpiresAt"] = AnyCodable(tokenData.expiresAt ?? "")
        usage.extra["userId"] = AnyCodable(response.userInfo?.userId ?? "")

        return usage
    }

    func emailLike(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.contains("@") else {
            return nil
        }
        return value
    }

    func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return string
            }
        }
        return nil
    }

    func buildEntries(from response: KiroUsageResponse) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        let defaultReset = response.nextDateReset.map { Date(timeIntervalSince1970: $0) }

        for breakdown in response.usageBreakdownList ?? [] {
            let displayName = breakdown.displayName ?? breakdown.resourceType ?? "Usage"
            let regularReset = breakdown.nextDateReset.map { Date(timeIntervalSince1970: $0) } ?? defaultReset

            if let freeTrial = breakdown.freeTrialInfo,
               freeTrial.freeTrialStatus?.uppercased() == "ACTIVE" {
                let used = freeTrial.currentUsageWithPrecision ?? freeTrial.currentUsage ?? 0
                let limit = freeTrial.usageLimitWithPrecision ?? freeTrial.usageLimit ?? 0
                if limit > 0 {
                    entries.append(UsageEntry(
                        label: "Bonus \(displayName)",
                        remainingPercent: remainingPercent(used: used, limit: limit),
                        resetAt: freeTrial.freeTrialExpiry.map { Date(timeIntervalSince1970: $0) } ?? regularReset
                    ))
                }
            }

            let used = breakdown.currentUsageWithPrecision ?? breakdown.currentUsage ?? 0
            let limit = breakdown.usageLimitWithPrecision ?? breakdown.usageLimit ?? 0
            if limit > 0 {
                let hasTrial = breakdown.freeTrialInfo?.freeTrialStatus?.uppercased() == "ACTIVE"
                entries.append(UsageEntry(
                    label: hasTrial ? "\(displayName) Base" : displayName,
                    remainingPercent: remainingPercent(used: used, limit: limit),
                    resetAt: regularReset
                ))
            }
        }

        if entries.isEmpty {
            entries.append(UsageEntry(label: "Agentic Requests", remainingPercent: 100, resetAt: defaultReset))
        }

        return entries
    }

    func createWindow(from entry: UsageEntry) -> RawQuotaWindow {
        var window = RawQuotaWindow()
        window.label = entry.label
        window.remainingPercent = entry.remainingPercent
        window.usedPercent = max(0, 100 - entry.remainingPercent)
        window.resetAt = entry.resetAt.map(iso8601String)
        window.resetDescription = formatResetDescription(entry.resetAt)
        return window
    }

    // MARK: - Helpers

    func extractRegionFromProfileArn(_ profileArn: String?) -> String? {
        guard let profileArn, !profileArn.isEmpty else { return nil }
        let parts = profileArn.split(separator: ":")
        guard parts.count >= 6,
              parts[0] == "arn",
              parts[2] == "codewhisperer",
              parts[3].contains("-") else { return nil }
        return String(parts[3])
    }

    func usageEndpoint(region: String) -> String {
        "https://q.\(region).amazonaws.com/getUsageLimits"
    }

    func socialTokenEndpoint(region: String) -> String {
        "https://prod.\(region).auth.desktop.kiro.dev/refreshToken"
    }

    func idcTokenEndpoint(region: String) -> String {
        "https://oidc.\(region).amazonaws.com/token"
    }

    func needsRefresh(_ expiresAt: String?) -> Bool {
        guard let expiry = parseISO8601(expiresAt) else { return false }
        return expiry.timeIntervalSinceNow <= Self.refreshBufferSeconds
    }

    func remainingPercent(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return min(100, max(0, (limit - used) / limit * 100))
    }

    func kiroUserAgent(for tokenData: KiroTokenData) -> String {
        let machineId = machineId(for: tokenData)
        return "aws-sdk-js/1.0.0 ua/2.1 os/darwin#\(darwinVersion()) lang/js md/nodejs#22.21.1 api/codewhispererruntime#1.0.0 m/N,E KiroIDE-\(Self.kiroVersion)-\(machineId)"
    }

    func kiroAmzUserAgent(for tokenData: KiroTokenData) -> String {
        let machineId = machineId(for: tokenData)
        return "aws-sdk-js/1.0.0 KiroIDE-\(Self.kiroVersion)-\(machineId)"
    }

    func machineId(for tokenData: KiroTokenData) -> String {
        let seed = tokenData.clientId ?? tokenData.refreshToken ?? tokenData.profileArn ?? tokenData.accessToken
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func darwinVersion() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return SharedFormatters.parseISO8601(value)
    }

    func iso8601String(_ date: Date) -> String {
        SharedFormatters.iso8601FractionalUTC.string(from: date)
    }

    func formatResetDescription(_ date: Date?) -> String {
        guard let date else { return "Reset unavailable" }
        let day = DateFormat.string(from: date, format: "MMM d")
        return "Resets \(day)"
    }

    func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        switch self {
        case .some(let value): return value.nilIfBlank
        case .none: return nil
        }
    }
}
