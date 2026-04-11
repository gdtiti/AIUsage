import XCTest
@testable import QuotaBackend

final class UsageNormalizerTests: XCTestCase {
    func testDashboardOverviewAggregatesAttentionResetAndCostSignals() {
        let now = Date()
        let soon = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 60 * 60))
        let later = ISO8601DateFormatter().string(from: now.addingTimeInterval(72 * 60 * 60))

        let summaries = [
            makeSummary(
                id: "copilot:main",
                providerId: "copilot",
                label: "Copilot",
                category: "subscription",
                status: "healthy",
                nextResetAt: soon
            ),
            makeSummary(
                id: "cursor:main",
                providerId: "cursor",
                label: "Cursor",
                category: "subscription",
                status: "critical",
                headlineSecondary: "Lowest remaining model family",
                nextResetAt: later
            ),
            makeSummary(
                id: "claude:local",
                providerId: "claude",
                label: "Claude Code Spend",
                category: "local-cost",
                status: "watch",
                headlineSecondary: "Weekly burn is rising",
                monthUsd: 12.34,
                weekTokens: 4567
            ),
            makeSummary(
                id: "warp:offline",
                providerId: "warp",
                label: "Warp",
                category: "subscription",
                status: "error"
            )
        ]

        let overview = UsageNormalizer.createDashboardOverview(
            summaries: summaries,
            generatedAt: ISO8601DateFormatter().string(from: now)
        )

        XCTAssertEqual(overview.activeProviders, 3)
        XCTAssertEqual(overview.attentionProviders, 2)
        XCTAssertEqual(overview.criticalProviders, 1)
        XCTAssertEqual(overview.resetSoonProviders, 1)
        XCTAssertEqual(overview.localWeekTokens, 4567)
        XCTAssertEqual(overview.localCostMonthUsd, 12.34, accuracy: 0.001)
        XCTAssertEqual(overview.alerts.count, 2)
        XCTAssertTrue(overview.alerts.contains(where: { $0.providerId == "cursor:main" && $0.tone == "critical" }))
        XCTAssertTrue(overview.alerts.contains(where: { $0.providerId == "claude:local" && $0.tone == "watch" }))
    }

    private func makeSummary(
        id: String,
        providerId: String,
        label: String,
        category: String,
        status: String,
        headlineSecondary: String = "Telemetry available",
        nextResetAt: String? = nil,
        monthUsd: Double? = nil,
        weekTokens: Int? = nil
    ) -> ProviderSummary {
        ProviderSummary(
            id: id,
            providerId: providerId,
            accountId: nil,
            name: label,
            label: label,
            description: "\(label) summary",
            category: category,
            channel: "cli",
            status: status,
            statusLabel: status.capitalized,
            theme: ThemeInfo(accent: "#4F46E5", glow: "#A5B4FC"),
            sourceLabel: "Test",
            sourceType: "test",
            fetchedAt: ISO8601DateFormatter().string(from: Date()),
            accountLabel: nil,
            membershipLabel: nil,
            remainingPercent: 42,
            nextResetAt: nextResetAt,
            nextResetLabel: nextResetAt == nil ? nil : "Reset soon",
            headline: HeadlineInfo(
                eyebrow: "Plan · Test",
                primary: "42%",
                secondary: headlineSecondary,
                supporting: "Unit test"
            ),
            metrics: [],
            windows: [],
            costSummary: monthUsd == nil && weekTokens == nil
                ? nil
                : CostSummaryInfo(
                    today: nil,
                    week: CostPeriod(usd: 1.23, tokens: weekTokens ?? 0, rangeLabel: "This week"),
                    month: CostPeriod(usd: monthUsd ?? 0, tokens: weekTokens ?? 0, rangeLabel: "This month")
                ),
            models: nil,
            spotlight: "Test spotlight",
            unpricedModels: nil,
            raw: nil
        )
    }
}
