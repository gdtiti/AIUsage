import Foundation
import XCTest
@testable import QuotaBackend

/// Guards against the DeepSeek double-count regression: `prompt_tokens` includes
/// cache-hit tokens, so naïvely setting `inputTokens = promptTokens` while also
/// reporting `cacheReadInputTokens = hit` causes the hit portion to be billed
/// at both input and cache-read prices. These tests lock the normalization
/// semantics across DeepSeek-flat, OpenAI-nested, and no-cache shapes.
final class OpenAIUsageCacheNormalizationTests: XCTestCase {

    // MARK: - Helper semantics

    func testDeepSeekFullShapeUsesMissAsInput() {
        let usage = OpenAIUsage(
            promptTokens: 1000,
            completionTokens: 50,
            totalTokens: 1050,
            promptCacheHitTokens: 800,
            promptCacheMissTokens: 200
        )
        XCTAssertEqual(usage.effectiveInputTokens, 200)
        XCTAssertEqual(usage.effectiveCachedTokens, 800)
    }

    func testOpenAINestedShapeSubtractsCachedFromPrompt() {
        let usage = OpenAIUsage(
            promptTokens: 1000,
            completionTokens: 50,
            totalTokens: 1050,
            promptTokensDetails: .init(cachedTokens: 800)
        )
        XCTAssertEqual(usage.effectiveInputTokens, 200)
        XCTAssertEqual(usage.effectiveCachedTokens, 800)
    }

    func testPlainUsageWithoutCacheFieldsPreservesPromptTokens() {
        let usage = OpenAIUsage(promptTokens: 1000, completionTokens: 50, totalTokens: 1050)
        XCTAssertEqual(usage.effectiveInputTokens, 1000)
        XCTAssertNil(usage.effectiveCachedTokens)
    }

    func testHitOnlyWithoutMissDerivesInputBySubtraction() {
        // Defensive path: if some gateway exposes hit but not miss, we still
        // avoid double-counting by subtracting hit from promptTokens.
        let usage = OpenAIUsage(
            promptTokens: 1000,
            completionTokens: 50,
            totalTokens: 1050,
            promptCacheHitTokens: 300
        )
        XCTAssertEqual(usage.effectiveInputTokens, 700)
        XCTAssertEqual(usage.effectiveCachedTokens, 300)
    }

    func testCorruptHitExceedingPromptClampsToZero() {
        // Defensive guard against broken upstreams returning hit > prompt.
        let usage = OpenAIUsage(
            promptTokens: 100,
            completionTokens: 10,
            totalTokens: 110,
            promptCacheHitTokens: 200
        )
        XCTAssertEqual(usage.effectiveInputTokens, 0)
        XCTAssertEqual(usage.effectiveCachedTokens, 200)
    }

    func testDeepSeekFieldsTakePrecedenceOverNestedDetails() {
        // DeepSeek-flat fields win when both are present; no gateway is
        // known to emit both, but the precedence should be deterministic.
        let usage = OpenAIUsage(
            promptTokens: 1000,
            completionTokens: 50,
            totalTokens: 1050,
            promptCacheHitTokens: 800,
            promptCacheMissTokens: 200,
            promptTokensDetails: .init(cachedTokens: 999)
        )
        XCTAssertEqual(usage.effectiveInputTokens, 200)
        XCTAssertEqual(usage.effectiveCachedTokens, 800)
    }

    // MARK: - JSON decoding

    func testDeepSeekJSONDecodesHitAndMissFields() throws {
        let json = """
        {
            "prompt_tokens": 1000,
            "completion_tokens": 50,
            "total_tokens": 1050,
            "prompt_cache_hit_tokens": 800,
            "prompt_cache_miss_tokens": 200
        }
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(OpenAIUsage.self, from: json)
        XCTAssertEqual(usage.promptCacheHitTokens, 800)
        XCTAssertEqual(usage.promptCacheMissTokens, 200)
        XCTAssertNil(usage.promptTokensDetails)
        XCTAssertEqual(usage.effectiveInputTokens, 200)
        XCTAssertEqual(usage.effectiveCachedTokens, 800)
    }

    func testOpenAINestedJSONDecodesCachedTokens() throws {
        let json = """
        {
            "prompt_tokens": 1000,
            "completion_tokens": 50,
            "total_tokens": 1050,
            "prompt_tokens_details": { "cached_tokens": 800 }
        }
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(OpenAIUsage.self, from: json)
        XCTAssertNil(usage.promptCacheHitTokens)
        XCTAssertEqual(usage.promptTokensDetails?.cachedTokens, 800)
        XCTAssertEqual(usage.effectiveInputTokens, 200)
        XCTAssertEqual(usage.effectiveCachedTokens, 800)
    }

    // MARK: - Mapper propagation

    func testStreamMapperPropagatesDeepSeekCacheSplit() {
        var mapper = CanonicalOpenAIUpstreamStreamMapper()
        var events: [CanonicalStreamEvent] = []
        events += mapper.map(.textDelta("hi"))
        events += mapper.map(.completed(
            finishReason: "stop",
            usage: OpenAIUsage(
                promptTokens: 1000,
                completionTokens: 50,
                totalTokens: 1050,
                promptCacheHitTokens: 800,
                promptCacheMissTokens: 200
            )
        ))

        let delta = events.compactMap { event -> CanonicalStreamMessageDelta? in
            if case .messageDelta(let d) = event { return d } else { return nil }
        }.last
        guard let delta, let usage = delta.usage else {
            return XCTFail("Expected message delta with usage")
        }
        XCTAssertEqual(usage.inputTokens, 200, "inputTokens must exclude cache-hit portion")
        XCTAssertEqual(usage.cacheReadInputTokens, 800)
        XCTAssertNil(usage.cacheCreationInputTokens)
    }

    func testResponseMapperPropagatesOpenAINestedCacheSplit() throws {
        let response = OpenAIChatCompletionResponse(
            id: "chatcmpl_test",
            created: 1_700_000_000,
            model: "gpt-4o-mini",
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(role: "assistant", content: .text("ok")),
                    finishReason: "stop"
                )
            ],
            usage: OpenAIUsage(
                promptTokens: 1000,
                completionTokens: 50,
                totalTokens: 1050,
                promptTokensDetails: .init(cachedTokens: 800)
            )
        )

        let canonical = try CanonicalResponseMapper().mapOpenAIChatCompletions(response)
        guard let usage = canonical.usage else {
            return XCTFail("Expected usage on canonical response")
        }
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cacheReadInputTokens, 800)
        XCTAssertNil(usage.cacheCreationInputTokens)
    }

    func testResponseMapperPassesThroughPromptTokensWhenNoCacheFields() throws {
        let response = OpenAIChatCompletionResponse(
            id: "chatcmpl_plain",
            created: 1_700_000_000,
            model: "gpt-4o-mini",
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(role: "assistant", content: .text("ok")),
                    finishReason: "stop"
                )
            ],
            usage: OpenAIUsage(promptTokens: 1000, completionTokens: 50, totalTokens: 1050)
        )

        let canonical = try CanonicalResponseMapper().mapOpenAIChatCompletions(response)
        guard let usage = canonical.usage else {
            return XCTFail("Expected usage on canonical response")
        }
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertNil(usage.cacheReadInputTokens)
    }
}
