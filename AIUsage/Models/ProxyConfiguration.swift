import Foundation
import SwiftUI

// MARK: - Node Type

enum NodeType: String, Codable, CaseIterable {
    case anthropicDirect
    case openaiProxy
}

// MARK: - Proxy Configuration

struct ProxyConfiguration: Codable, Identifiable {
    let id: String
    var name: String
    var nodeType: NodeType
    var isEnabled: Bool

    // Anthropic Direct fields
    var anthropicBaseURL: String
    var anthropicAPIKey: String

    // OpenAI Proxy fields
    var host: String
    var port: Int
    var allowLAN: Bool
    var upstreamBaseURL: String
    var upstreamAPIKey: String
    var expectedClientKey: String
    var defaultModel: String
    var modelMapping: ModelMapping
    var maxOutputTokens: Int // 0 = no cap, pass through original value

    var createdAt: Date
    var lastUsedAt: Date?

    enum PricingCurrency: String, Codable, CaseIterable {
        case usd
        case cny
    }

    struct ModelPricing: Codable {
        var inputPerMillion: Double    // per 1M input tokens (in configured currency)
        var outputPerMillion: Double   // per 1M output tokens
        var cachePerMillion: Double    // per 1M cache hit tokens
        var currency: PricingCurrency

        static var zero: ModelPricing {
            ModelPricing(inputPerMillion: 0, outputPerMillion: 0, cachePerMillion: 0, currency: .usd)
        }

        private static let cnyToUsdRate: Double = 1.0 / 7.3

        var inputPerMillionUSD: Double {
            currency == .usd ? inputPerMillion : inputPerMillion * Self.cnyToUsdRate
        }
        var outputPerMillionUSD: Double {
            currency == .usd ? outputPerMillion : outputPerMillion * Self.cnyToUsdRate
        }
        var cachePerMillionUSD: Double {
            currency == .usd ? cachePerMillion : cachePerMillion * Self.cnyToUsdRate
        }

        func costForTokens(input: Int, output: Int, cache: Int) -> Double {
            (Double(input) * inputPerMillionUSD + Double(output) * outputPerMillionUSD + Double(cache) * cachePerMillionUSD) / 1_000_000
        }

        init(inputPerMillion: Double = 0, outputPerMillion: Double = 0, cachePerMillion: Double = 0, currency: PricingCurrency = .usd) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cachePerMillion = cachePerMillion
            self.currency = currency
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
            outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)
            cachePerMillion = try container.decode(Double.self, forKey: .cachePerMillion)
            currency = try container.decodeIfPresent(PricingCurrency.self, forKey: .currency) ?? .usd
        }
    }

    struct MappedModel: Codable {
        var name: String
        var pricing: ModelPricing

        init(name: String, pricing: ModelPricing = .zero) {
            self.name = name
            self.pricing = pricing
        }
    }

    struct ModelMapping: Codable {
        var bigModel: MappedModel      // opus -> this
        var middleModel: MappedModel   // sonnet -> this
        var smallModel: MappedModel    // haiku -> this

        static var `default`: ModelMapping {
            ModelMapping(
                bigModel: MappedModel(name: "gpt-4o"),
                middleModel: MappedModel(name: "gpt-4o-mini"),
                smallModel: MappedModel(name: "gpt-3.5-turbo")
            )
        }

        func pricingForUpstreamModel(_ model: String) -> ModelPricing? {
            if bigModel.name == model { return bigModel.pricing }
            if middleModel.name == model { return middleModel.pricing }
            if smallModel.name == model { return smallModel.pricing }
            return nil
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        nodeType: NodeType = .openaiProxy,
        isEnabled: Bool = false,
        anthropicBaseURL: String = "https://api.anthropic.com",
        anthropicAPIKey: String = "",
        host: String = "127.0.0.1",
        port: Int = 8080,
        allowLAN: Bool = false,
        upstreamBaseURL: String = "https://api.openai.com/v1",
        upstreamAPIKey: String = "",
        expectedClientKey: String = "",
        defaultModel: String = "",
        modelMapping: ModelMapping = .default,
        maxOutputTokens: Int = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.nodeType = nodeType
        self.isEnabled = isEnabled
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicAPIKey = anthropicAPIKey
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.upstreamBaseURL = upstreamBaseURL
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.defaultModel = defaultModel
        self.modelMapping = modelMapping
        self.maxOutputTokens = maxOutputTokens
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nodeType = try container.decodeIfPresent(NodeType.self, forKey: .nodeType) ?? .openaiProxy
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        anthropicBaseURL = try container.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? "https://api.anthropic.com"
        anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        allowLAN = try container.decode(Bool.self, forKey: .allowLAN)
        upstreamBaseURL = try container.decode(String.self, forKey: .upstreamBaseURL)
        upstreamAPIKey = try container.decode(String.self, forKey: .upstreamAPIKey)
        expectedClientKey = try container.decode(String.self, forKey: .expectedClientKey)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        modelMapping = try container.decode(ModelMapping.self, forKey: .modelMapping)
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    var bindAddress: String {
        allowLAN ? "0.0.0.0" : host
    }

    var displayURL: String {
        switch nodeType {
        case .anthropicDirect:
            return anthropicBaseURL
        case .openaiProxy:
            return "http://\(host):\(port)"
        }
    }
}

// MARK: - Proxy Statistics

struct ProxyStatistics: Codable {
    var totalRequests: Int
    var successfulRequests: Int
    var failedRequests: Int
    var totalTokensInput: Int
    var totalTokensOutput: Int
    var totalTokensCache: Int
    var estimatedCostUSD: Double
    var requestsByModel: [String: Int]
    var lastRequestAt: Date?
    var averageResponseTime: Double

    static var empty: ProxyStatistics {
        ProxyStatistics(
            totalRequests: 0,
            successfulRequests: 0,
            failedRequests: 0,
            totalTokensInput: 0,
            totalTokensOutput: 0,
            totalTokensCache: 0,
            estimatedCostUSD: 0,
            requestsByModel: [:],
            lastRequestAt: nil,
            averageResponseTime: 0
        )
    }

    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successfulRequests) / Double(totalRequests) * 100
    }

    var totalTokens: Int {
        totalTokensInput + totalTokensOutput + totalTokensCache
    }
}

// MARK: - Proxy Request Log

struct ProxyRequestLog: Codable, Identifiable {
    let id: String
    let configId: String
    let timestamp: Date
    let method: String
    let path: String
    let claudeModel: String
    let upstreamModel: String
    let success: Bool
    let responseTimeMs: Double
    let tokensInput: Int
    let tokensOutput: Int
    let tokensCache: Int
    let estimatedCostUSD: Double
    let errorMessage: String?

    init(
        id: String = UUID().uuidString,
        configId: String,
        timestamp: Date = Date(),
        method: String,
        path: String,
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        tokensInput: Int = 0,
        tokensOutput: Int = 0,
        tokensCache: Int = 0,
        estimatedCostUSD: Double = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.configId = configId
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.claudeModel = claudeModel
        self.upstreamModel = upstreamModel
        self.success = success
        self.responseTimeMs = responseTimeMs
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
        self.tokensCache = tokensCache
        self.estimatedCostUSD = estimatedCostUSD
        self.errorMessage = errorMessage
    }
}
