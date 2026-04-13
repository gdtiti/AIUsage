import Foundation

// MARK: - Claude Proxy Service

public actor ClaudeProxyService {
    private let configuration: ClaudeProxyConfiguration
    private let upstreamClient: OpenAICompatibleClient
    private let claudeToOpenAI: ClaudeToOpenAIConverter
    private let openAIToClaude: OpenAIToClaudeConverter

    public init(configuration: ClaudeProxyConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        self.upstreamClient = OpenAICompatibleClient(configuration: configuration)
        self.claudeToOpenAI = ClaudeToOpenAIConverter()
        self.openAIToClaude = OpenAIToClaudeConverter()
    }

    // MARK: - Authentication

    public func authenticate(headers: [String: String]) -> Bool {
        guard let expectedKey = configuration.expectedClientAPIKey else {
            // No authentication required
            return true
        }

        // Check x-api-key header
        if let apiKey = headers["x-api-key"], apiKey == expectedKey {
            return true
        }

        // Check Authorization: Bearer header
        if let auth = headers["authorization"] {
            let bearer = "Bearer "
            if auth.hasPrefix(bearer) {
                let token = String(auth.dropFirst(bearer.count))
                if token == expectedKey {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Non-Streaming Messages

    public func handleMessages(
        request: ClaudeMessageRequest
    ) async throws -> ClaudeMessageResponse {
        let upstreamModel = configuration.mapToUpstreamModel(request.model)

        var openAIRequest = try claudeToOpenAI.convert(
            request: request,
            upstreamModel: upstreamModel
        )

        if let cap = configuration.maxOutputTokens, cap > 0,
           let current = openAIRequest.maxTokens, current > cap {
            openAIRequest = OpenAIChatCompletionRequest(
                model: openAIRequest.model,
                messages: openAIRequest.messages,
                temperature: openAIRequest.temperature,
                topP: openAIRequest.topP,
                maxTokens: cap,
                stop: openAIRequest.stop,
                stream: openAIRequest.stream,
                tools: openAIRequest.tools,
                toolChoice: openAIRequest.toolChoice
            )
        }

        let openAIResponse = try await upstreamClient.sendChatCompletion(request: openAIRequest)

        // Convert back to Claude response
        let claudeResponse = try openAIToClaude.convert(
            response: openAIResponse,
            originalModel: request.model
        )

        return claudeResponse
    }

    // MARK: - Token Counting

    public func handleCountTokens(
        request: ClaudeTokenCountRequest
    ) async throws -> ClaudeTokenCountResponse {
        // Simple estimation: character count / 4
        var totalChars = 0

        // Count system message
        if let system = request.system {
            totalChars += system.count
        }

        // Count messages
        for message in request.messages {
            switch message.content {
            case .text(let text):
                totalChars += text.count
            case .blocks(let blocks):
                for block in blocks {
                    switch block {
                    case .text(let textBlock):
                        totalChars += textBlock.text.count
                    case .toolUse(let toolUse):
                        totalChars += toolUse.name.count
                        // Estimate tool input size
                        totalChars += 50
                    case .toolResult(let result):
                        totalChars += result.content?.count ?? 0
                    case .image:
                        totalChars += 4000
                    case .unknown:
                        totalChars += 100
                    }
                }
            }
        }

        // Count tools
        if let tools = request.tools {
            for tool in tools {
                totalChars += tool.name.count
                totalChars += tool.description?.count ?? 0
                totalChars += 100 // Estimate for schema
            }
        }

        let estimatedTokens = max(1, totalChars / 4)

        return ClaudeTokenCountResponse(inputTokens: estimatedTokens)
    }

    // MARK: - Streaming Support

    public func mapModel(_ claudeModel: String) -> String {
        configuration.mapToUpstreamModel(claudeModel)
    }

    public func sendStreamingRequest(
        openAIRequest: OpenAIChatCompletionRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var cappedMaxTokens = openAIRequest.maxTokens
        if let cap = configuration.maxOutputTokens, cap > 0,
           let current = cappedMaxTokens, current > cap {
            cappedMaxTokens = cap
        }
        let streamingRequest = OpenAIChatCompletionRequest(
            model: openAIRequest.model,
            messages: openAIRequest.messages,
            temperature: openAIRequest.temperature,
            topP: openAIRequest.topP,
            maxTokens: cappedMaxTokens,
            stop: openAIRequest.stop,
            stream: true,
            tools: openAIRequest.tools,
            toolChoice: openAIRequest.toolChoice
        )
        return try await upstreamClient.sendStreamingChatCompletion(request: streamingRequest)
    }

    // MARK: - Error Handling

    public func buildErrorResponse(error: Error) -> ClaudeErrorResponse {
        let errorType: String
        let errorMessage: String

        switch error {
        case let configError as ConfigurationError:
            errorType = "invalid_request_error"
            errorMessage = configError.localizedDescription

        case let upstreamError as UpstreamError:
            errorType = "api_error"
            errorMessage = upstreamError.localizedDescription

        case let conversionError as ConversionError:
            errorType = "invalid_request_error"
            errorMessage = conversionError.localizedDescription

        default:
            errorType = "api_error"
            errorMessage = error.localizedDescription
        }

        return ClaudeErrorResponse(
            type: "error",
            error: ClaudeError(
                type: errorType,
                message: errorMessage
            )
        )
    }
}
