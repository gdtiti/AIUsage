import Foundation

// MARK: - Claude to OpenAI Converter

public struct ClaudeToOpenAIConverter {

    public init() {}

    // MARK: - Request Conversion

    public func convert(
        request: ClaudeMessageRequest,
        upstreamModel: String
    ) throws -> OpenAIChatCompletionRequest {
        var openAIMessages: [OpenAIChatMessage] = []

        // Add system message if present
        if let system = request.system, !system.isEmpty {
            openAIMessages.append(OpenAIChatMessage(
                role: "system",
                content: .text(system)
            ))
        }

        // Convert Claude messages to OpenAI messages
        for claudeMsg in request.messages {
            let openAIMsg = try convertMessage(claudeMsg)
            openAIMessages.append(openAIMsg)
        }

        // Convert tools if present
        let openAITools = request.tools?.map { convertTool($0) }

        // Convert tool choice
        let openAIToolChoice = request.toolChoice.map { convertToolChoice($0) }

        return OpenAIChatCompletionRequest(
            model: upstreamModel,
            messages: openAIMessages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stopSequences,
            stream: request.stream,
            tools: openAITools,
            toolChoice: openAIToolChoice
        )
    }

    // MARK: - Message Conversion

    private func convertMessage(_ message: ClaudeMessage) throws -> OpenAIChatMessage {
        switch message.content {
        case .text(let text):
            return OpenAIChatMessage(
                role: message.role,
                content: .text(text)
            )

        case .blocks(let blocks):
            return try convertBlocksMessage(role: message.role, blocks: blocks)
        }
    }

    private func convertBlocksMessage(role: String, blocks: [ClaudeContentBlock]) throws -> OpenAIChatMessage {
        // Check if this is an assistant message with tool calls
        let toolUseBlocks = blocks.compactMap { block -> ClaudeToolUseBlock? in
            if case .toolUse(let toolUse) = block {
                return toolUse
            }
            return nil
        }

        if !toolUseBlocks.isEmpty && role == "assistant" {
            // Convert to assistant message with tool calls
            let toolCalls = try toolUseBlocks.map { try convertToolUseToToolCall($0) }
            let textContent = blocks.compactMap { block -> String? in
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined(separator: "\n")

            return OpenAIChatMessage(
                role: "assistant",
                content: textContent.isEmpty ? nil : .text(textContent),
                toolCalls: toolCalls
            )
        }

        // Check if this is a user message with tool results
        let toolResultBlocks = blocks.compactMap { block -> ClaudeToolResultBlock? in
            if case .toolResult(let result) = block {
                return result
            }
            return nil
        }

        if !toolResultBlocks.isEmpty && role == "user" {
            // For tool results, we need to create separate tool messages
            // Return the first one and handle multiple results separately
            if let firstResult = toolResultBlocks.first {
                return OpenAIChatMessage(
                    role: "tool",
                    content: .text(firstResult.content ?? ""),
                    toolCallId: firstResult.toolUseId
                )
            }
        }

        // Regular content blocks (text and images)
        let parts = try blocks.compactMap { try convertContentBlock($0) }

        if parts.count == 1, case .text(let textPart) = parts[0] {
            return OpenAIChatMessage(
                role: role,
                content: .text(textPart.text)
            )
        }

        return OpenAIChatMessage(
            role: role,
            content: .parts(parts)
        )
    }

    private func convertContentBlock(_ block: ClaudeContentBlock) throws -> OpenAIContentPart? {
        switch block {
        case .text(let textBlock):
            return .text(OpenAITextPart(text: textBlock.text))

        case .image(let imageBlock):
            // Convert base64 image to data URL
            let dataURL = "data:\(imageBlock.source.mediaType);base64,\(imageBlock.source.data)"
            return .imageUrl(OpenAIImageUrlPart(
                imageUrl: OpenAIImageUrl(url: dataURL)
            ))

        case .toolUse, .toolResult, .unknown:
            return nil
        }
    }

    // MARK: - Tool Conversion

    private func convertTool(_ tool: ClaudeTool) -> OpenAITool {
        OpenAITool(
            type: "function",
            function: OpenAIFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.inputSchema
            )
        )
    }

    private func convertToolChoice(_ choice: ClaudeToolChoice) -> OpenAIToolChoice {
        switch choice.type {
        case "auto":
            return .auto
        case "any":
            return .required
        case "tool":
            if let name = choice.name {
                return .function(name)
            }
            return .auto
        default:
            return .auto
        }
    }

    private func convertToolUseToToolCall(_ toolUse: ClaudeToolUseBlock) throws -> OpenAIToolCall {
        let argumentsData = try JSONSerialization.data(withJSONObject: toolUse.input.mapValues { $0.value })
        let argumentsString = String(data: argumentsData, encoding: .utf8) ?? "{}"

        return OpenAIToolCall(
            id: toolUse.id,
            type: "function",
            function: OpenAIFunctionCall(
                name: toolUse.name,
                arguments: argumentsString
            )
        )
    }
}
