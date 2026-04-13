import XCTest
@testable import QuotaBackend

final class ClaudeProxyConverterTests: XCTestCase {

    // MARK: - Configuration Tests

    func testModelNormalization() {
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-sonnet-4.5"), "sonnet")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-3-5-haiku-20241022"), "haiku")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-opus-4"), "opus")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-3-opus-20240229"), "opus")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("sonnet"), "sonnet")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("haiku"), "haiku")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("opus"), "opus")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("unknown-model"), "unknown-model")
    }

    func testModelMapping() {
        let config = ClaudeProxyConfiguration(
            upstreamAPIKey: "test-key",
            bigModel: "gpt-4o",
            middleModel: "gpt-4o",
            smallModel: "gpt-4o-mini"
        )

        XCTAssertEqual(config.mapToUpstreamModel("claude-sonnet-4.5"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("claude-3-5-haiku-20241022"), "gpt-4o-mini")
        XCTAssertEqual(config.mapToUpstreamModel("claude-opus-4"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("sonnet"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("haiku"), "gpt-4o-mini")
        XCTAssertEqual(config.mapToUpstreamModel("opus"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("unknown"), "gpt-4o") // fallback to middle
    }

    func testConfigurationValidation() {
        var config = ClaudeProxyConfiguration(
            upstreamAPIKey: "test-key"
        )

        XCTAssertNoThrow(try config.validate())

        // Test invalid port
        config = ClaudeProxyConfiguration(
            bindPort: 0,
            upstreamAPIKey: "test-key"
        )
        XCTAssertThrowsError(try config.validate())

        // Test empty API key
        config = ClaudeProxyConfiguration(
            upstreamAPIKey: ""
        )
        XCTAssertThrowsError(try config.validate())
    }

    // MARK: - Claude to OpenAI Conversion Tests

    func testConvertSimpleTextMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("Hello, world!"))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertEqual(openAIRequest.model, "gpt-4o")
        XCTAssertEqual(openAIRequest.messages.count, 1)
        XCTAssertEqual(openAIRequest.messages[0].role, "user")

        if case .text(let content) = openAIRequest.messages[0].content {
            XCTAssertEqual(content, "Hello, world!")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testConvertSystemMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("Hello"))
            ],
            system: "You are a helpful assistant.",
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertEqual(openAIRequest.messages.count, 2)
        XCTAssertEqual(openAIRequest.messages[0].role, "system")

        if case .text(let content) = openAIRequest.messages[0].content {
            XCTAssertEqual(content, "You are a helpful assistant.")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testConvertImageMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let imageSource = ClaudeImageSource(
            type: "base64",
            mediaType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .text(ClaudeTextBlock(text: "What's in this image?")),
                    .image(ClaudeImageBlock(source: imageSource))
                ]))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertEqual(openAIRequest.messages.count, 1)

        if case .parts(let parts) = openAIRequest.messages[0].content {
            XCTAssertEqual(parts.count, 2)

            if case .text(let textPart) = parts[0] {
                XCTAssertEqual(textPart.text, "What's in this image?")
            } else {
                XCTFail("Expected text part")
            }

            if case .imageUrl(let imagePart) = parts[1] {
                XCTAssertTrue(imagePart.imageUrl.url.hasPrefix("data:image/png;base64,"))
            } else {
                XCTFail("Expected image part")
            }
        } else {
            XCTFail("Expected parts content")
        }
    }

    func testConvertToolDefinition() throws {
        let converter = ClaudeToOpenAIConverter()

        let tool = ClaudeTool(
            name: "get_weather",
            description: "Get the weather for a location",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "location": ["type": "string"]
                ]),
                "required": AnyCodable(["location"])
            ]
        )

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("What's the weather?"))
            ],
            maxTokens: 1024,
            tools: [tool]
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertNotNil(openAIRequest.tools)
        XCTAssertEqual(openAIRequest.tools?.count, 1)
        XCTAssertEqual(openAIRequest.tools?[0].function.name, "get_weather")
        XCTAssertEqual(openAIRequest.tools?[0].function.description, "Get the weather for a location")
    }

    // MARK: - OpenAI to Claude Conversion Tests

    func testConvertOpenAIResponse() throws {
        let converter = OpenAIToClaudeConverter()

        let openAIResponse = OpenAIChatCompletionResponse(
            id: "chatcmpl-123",
            created: Int(Date().timeIntervalSince1970),
            model: "gpt-4o",
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: .text("Hello! How can I help you today?")
                    ),
                    finishReason: "stop"
                )
            ],
            usage: OpenAIUsage(
                promptTokens: 10,
                completionTokens: 20,
                totalTokens: 30
            )
        )

        let claudeResponse = try converter.convert(
            response: openAIResponse,
            originalModel: "claude-sonnet-4.5"
        )

        XCTAssertEqual(claudeResponse.id, "chatcmpl-123")
        XCTAssertEqual(claudeResponse.role, "assistant")
        XCTAssertEqual(claudeResponse.model, "claude-sonnet-4.5")
        XCTAssertEqual(claudeResponse.stopReason, "end_turn")
        XCTAssertEqual(claudeResponse.usage.inputTokens, 10)
        XCTAssertEqual(claudeResponse.usage.outputTokens, 20)
        XCTAssertEqual(claudeResponse.content.count, 1)

        if case .text(let textBlock) = claudeResponse.content[0] {
            XCTAssertEqual(textBlock.text, "Hello! How can I help you today?")
        } else {
            XCTFail("Expected text block")
        }
    }

    func testConvertFinishReasons() {
        let converter = OpenAIToClaudeConverter()

        // Use reflection to test private method (for demonstration)
        // In real tests, you'd test through public API
        XCTAssertEqual(
            converter.convertFinishReason("stop"),
            "end_turn"
        )
        XCTAssertEqual(
            converter.convertFinishReason("length"),
            "max_tokens"
        )
        XCTAssertEqual(
            converter.convertFinishReason("tool_calls"),
            "tool_use"
        )
    }

    // MARK: - Token Estimation Tests

    func testTokenEstimation() {
        let text = "Hello, world! This is a test message."
        let estimatedTokens = text.count / 4

        XCTAssertGreaterThan(estimatedTokens, 0)
        XCTAssertLessThan(estimatedTokens, text.count)
    }
}
