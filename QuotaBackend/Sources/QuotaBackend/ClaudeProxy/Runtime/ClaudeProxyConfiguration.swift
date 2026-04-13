import Foundation

// MARK: - Proxy Configuration for QuotaBackend

public struct ClaudeProxyConfiguration: Sendable {
    public let enabled: Bool
    public let upstreamBaseURL: String
    public let upstreamAPIKey: String
    public let expectedClientKey: String?
    public let bigModel: String
    public let middleModel: String
    public let smallModel: String
    public let maxOutputTokens: Int?
    public let requestTimeout: TimeInterval
    public let customHeaders: [String: String]

    public init(
        enabled: Bool,
        upstreamBaseURL: String,
        upstreamAPIKey: String,
        expectedClientKey: String? = nil,
        bigModel: String = "gpt-4o",
        middleModel: String = "gpt-4o-mini",
        smallModel: String = "gpt-3.5-turbo",
        maxOutputTokens: Int? = nil,
        requestTimeout: TimeInterval = 60,
        customHeaders: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.upstreamBaseURL = upstreamBaseURL
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.bigModel = bigModel
        self.middleModel = middleModel
        self.smallModel = smallModel
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
        self.customHeaders = customHeaders
    }

    public func mapToUpstreamModel(_ requestModel: String) -> String {
        let normalized = requestModel.lowercased()
        if normalized.contains("opus") {
            return bigModel
        } else if normalized.contains("sonnet") {
            return middleModel
        } else if normalized.contains("haiku") {
            return smallModel
        } else if normalized.contains("claude") {
            return middleModel
        }
        return requestModel
    }

    public func validate() throws {
        if upstreamAPIKey.isEmpty {
            throw ConfigurationError.missingAPIKey
        }
        if upstreamBaseURL.isEmpty {
            throw ConfigurationError.invalidURL
        }
    }

    public var expectedClientAPIKey: String? {
        return expectedClientKey
    }

    public static func loadFromEnvironment() -> ClaudeProxyConfiguration? {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            return nil
        }

        let baseURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1"
        let clientKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let bigModel = ProcessInfo.processInfo.environment["BIG_MODEL"] ?? "gpt-4o"
        let middleModel = ProcessInfo.processInfo.environment["MIDDLE_MODEL"] ?? "gpt-4o-mini"
        let smallModel = ProcessInfo.processInfo.environment["SMALL_MODEL"] ?? "gpt-3.5-turbo"
        let maxOutputTokens = ProcessInfo.processInfo.environment["MAX_OUTPUT_TOKENS"].flatMap { Int($0) }

        return ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: baseURL,
            upstreamAPIKey: apiKey,
            expectedClientKey: clientKey,
            bigModel: bigModel,
            middleModel: middleModel,
            smallModel: smallModel,
            maxOutputTokens: maxOutputTokens
        )
    }
}

// MARK: - Configuration Error

public enum ConfigurationError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidModel

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing API key"
        case .invalidURL:
            return "Invalid upstream URL"
        case .invalidModel:
            return "Invalid model configuration"
        }
    }
}
