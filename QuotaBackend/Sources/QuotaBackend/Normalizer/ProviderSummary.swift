import Foundation

// MARK: - Normalized Provider Summary
// This matches the JSON shape the SwiftUI frontend already expects (ProviderData in ProviderModels.swift)

public struct ProviderSummary: Codable, Sendable {
    public var id: String
    public var providerId: String
    public var accountId: String?
    public let name: String
    public var label: String
    public var description: String
    public var category: String
    public var channel: String?
    public var status: String
    public var statusLabel: String
    public var theme: ThemeInfo
    public var sourceLabel: String
    public var sourceType: String
    public var fetchedAt: String?
    public var accountLabel: String?
    public var membershipLabel: String?
    public var remainingPercent: Double?
    public var nextResetAt: String?
    public var nextResetLabel: String?
    public var headline: HeadlineInfo
    public var metrics: [MetricInfo]
    public var windows: [WindowInfo]
    public var costSummary: CostSummaryInfo?
    public var models: [ModelInfo]?
    public var spotlight: String
    public var unpricedModels: [String]?
    public var raw: ProviderUsage?
}

public struct ThemeInfo: Codable, Sendable {
    public let accent: String
    public let glow: String
}

public struct HeadlineInfo: Codable, Sendable {
    public let eyebrow: String
    public let primary: String
    public let secondary: String
    public let supporting: String
}

public struct MetricInfo: Codable, Sendable {
    public let label: String
    public let value: String
    public var note: String?
}

public struct WindowInfo: Codable, Sendable {
    public let label: String
    public var remainingPercent: Double?
    public var usedPercent: Double?
    public let value: String
    public let note: String
    public var resetAt: String?
}

public struct CostSummaryInfo: Codable, Sendable {
    public var today: CostPeriod?
    public var week: CostPeriod?
    public var month: CostPeriod?
    public var timeline: CostTimelineInfo?
}

public struct CostPeriod: Codable, Sendable {
    public let usd: Double
    public let tokens: Int
    public let rangeLabel: String
}

public struct CostTimelineInfo: Codable, Sendable {
    public var hourly: [CostTimelinePoint]
    public var daily: [CostTimelinePoint]
}

public struct CostTimelinePoint: Codable, Sendable {
    public let bucket: String
    public let label: String
    public let usd: Double
    public let tokens: Int
}

public struct ModelInfo: Codable, Sendable {
    public let label: String
    public let value: String
    public var note: String?
}

// MARK: - Dashboard Response (matches existing Node.js API shape)

public struct DashboardSnapshot: Codable, Sendable {
    public let generatedAt: String
    public let overview: DashboardOverview
    public let providers: [ProviderResult]
}

public struct DashboardOverview: Codable, Sendable {
    public let generatedAt: String
    public let activeProviders: Int
    public let attentionProviders: Int
    public let criticalProviders: Int
    public let resetSoonProviders: Int
    public let localCostMonthUsd: Double
    public let localWeekTokens: Int
    public let stats: [StatInfo]
    public let alerts: [AlertInfo]
}

public struct StatInfo: Codable, Sendable {
    public let label: String
    public let value: String
    public let note: String
}

public struct AlertInfo: Codable, Sendable {
    public let tone: String
    public let providerId: String
    public let title: String
    public let body: String
}
