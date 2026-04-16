import Foundation

// MARK: - OpenAI to Claude Converter

// Reference converter retained as a regression baseline for tests.
// Production response building now flows through the canonical layer.
public struct OpenAIToClaudeConverter {

    public init() {}

    // MARK: - Response Conversion

    public func convert(
        response: OpenAIChatCompletionResponse,
        originalModel: String
    ) throws -> ClaudeMessageResponse {
        guard let firstChoice = response.choices.first else {
            throw ConversionError.noChoicesInResponse
        }

        let content = try convertMessageToContent(firstChoice.message)
        let stopReason = convertFinishReason(firstChoice.finishReason)

        let usage = ClaudeUsage(
            inputTokens: response.usage?.promptTokens ?? 0,
            outputTokens: response.usage?.completionTokens ?? 0
        )

        return ClaudeMessageResponse(
            id: response.id,
            type: "message",
            role: "assistant",
            content: content,
            model: originalModel,
            stopReason: stopReason,
            stopSequence: nil,
            usage: usage
        )
    }

    // MARK: - Streaming Conversion

    public func convertStreamChunk(
        chunk: OpenAIStreamChunk,
        originalModel: String
    ) throws -> ClaudeStreamEvent {
        guard let firstChoice = chunk.choices.first else {
            throw ConversionError.noChoicesInResponse
        }

        let delta = firstChoice.delta

        // Determine event type based on delta content
        if let role = delta.role {
            // Message start
            return .messageStart(ClaudeMessageStartEvent(
                message: ClaudeMessageStart(
                    id: chunk.id,
                    type: "message",
                    role: role,
                    model: originalModel
                )
            ))
        }

        if let content = delta.content, !content.isEmpty {
            // Content block delta
            return .contentBlockDelta(ClaudeContentBlockDeltaEvent(
                index: 0,
                delta: .text(ClaudeTextDelta(type: "text_delta", text: content))
            ))
        }

        if let toolCalls = delta.toolCalls, !toolCalls.isEmpty {
            // Tool use delta
            let toolCall = toolCalls[0]
            if let id = toolCall.id, let name = toolCall.function?.name {
                // Tool use start
                return .contentBlockStart(ClaudeContentBlockStartEvent(
                    index: toolCall.index,
                    contentBlock: .toolUse(ClaudeToolUseBlock(
                        id: id,
                        name: name,
                        input: [:]
                    ))
                ))
            } else if let args = toolCall.function?.arguments {
                // Tool use input delta
                return .contentBlockDelta(ClaudeContentBlockDeltaEvent(
                    index: toolCall.index,
                    delta: .inputJson(ClaudeInputJsonDelta(type: "input_json_delta", partialJson: args))
                ))
            }
        }

        if firstChoice.finishReason != nil {
            // Message stop
            return .messageStop
        }

        // Ping event (no meaningful content)
        return .ping
    }

    // MARK: - Helper Methods

    private func convertMessageToContent(_ message: OpenAIChatMessage) throws -> [ClaudeContentBlock] {
        var blocks: [ClaudeContentBlock] = []

        // Add text content if present
        if let content = message.content {
            switch content {
            case .text(let text):
                if !text.isEmpty {
                    blocks.append(.text(ClaudeTextBlock(text: text)))
                }
            case .parts(let parts):
                for part in parts {
                    switch part {
                    case .text(let textPart):
                        blocks.append(.text(ClaudeTextBlock(text: textPart.text)))
                    case .inputFile(let filePart):
                        var source: [String: AnyCodable] = [
                            "type": AnyCodable("file")
                        ]
                        if let fileId = filePart.fileId {
                            source["file_id"] = AnyCodable(fileId)
                        }
                        blocks.append(.document(ClaudeDocumentBlock(
                            source: source,
                            title: filePart.filename
                        )))
                    case .imageUrl:
                        break
                    case .unknown:
                        break
                    }
                }
            }
        }

        // Add tool calls if present
        if let toolCalls = message.toolCalls {
            for toolCall in toolCalls {
                let input = try parseToolArguments(toolCall.function.arguments)
                blocks.append(.toolUse(ClaudeToolUseBlock(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    input: input
                )))
            }
        }

        // If no blocks, add empty text block
        if blocks.isEmpty {
            blocks.append(.text(ClaudeTextBlock(text: "")))
        }

        return blocks
    }

    private func parseToolArguments(_ arguments: String) throws -> [String: AnyCodable] {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        return json.mapValues { AnyCodable($0) }
    }

    public func convertFinishReason(_ reason: String?) -> String? {
        guard let reason else { return nil }

        switch reason {
        case "stop":
            return "end_turn"
        case "length":
            return "max_tokens"
        case "tool_calls":
            return "tool_use"
        case "pause_turn":
            return "pause_turn"
        case "refusal", "content_filter":
            return "refusal"
        case "model_context_window_exceeded":
            return "model_context_window_exceeded"
        default:
            return "end_turn"
        }
    }
}

// MARK: - Claude Streaming Events

public enum ClaudeStreamEvent {
    case messageStart(ClaudeMessageStartEvent)
    case contentBlockStart(ClaudeContentBlockStartEvent)
    case contentBlockDelta(ClaudeContentBlockDeltaEvent)
    case contentBlockStop(ClaudeContentBlockStopEvent)
    case messageDelta(ClaudeMessageDeltaEvent)
    case messageStop
    case ping
}

public struct ClaudeMessageStartEvent: Codable, Sendable {
    public let type: String = "message_start"
    public let message: ClaudeMessageStart

    enum CodingKeys: String, CodingKey {
        case type, message
    }

    public init(message: ClaudeMessageStart) {
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "message_start" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected message_start event, got \(type)"
            )
        }
        self.message = try container.decode(ClaudeMessageStart.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(message, forKey: .message)
    }
}

public struct ClaudeMessageStart: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let content: [ClaudeContentBlock]
    public let model: String
    public let stopReason: String?
    public let stopSequence: String?
    public let usage: ClaudeUsage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }

    public init(
        id: String,
        type: String,
        role: String,
        content: [ClaudeContentBlock] = [],
        model: String,
        stopReason: String? = nil,
        stopSequence: String? = nil,
        usage: ClaudeUsage = ClaudeUsage(inputTokens: 0, outputTokens: 0)
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }
}

public struct ClaudeContentBlockStartEvent: Codable, Sendable {
    public let type: String = "content_block_start"
    public let index: Int
    public let contentBlock: ClaudeContentBlock

    enum CodingKeys: String, CodingKey {
        case type, index
        case contentBlock = "content_block"
    }

    public init(index: Int, contentBlock: ClaudeContentBlock) {
        self.index = index
        self.contentBlock = contentBlock
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "content_block_start" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected content_block_start event, got \(type)"
            )
        }
        self.index = try container.decode(Int.self, forKey: .index)
        self.contentBlock = try container.decode(ClaudeContentBlock.self, forKey: .contentBlock)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(index, forKey: .index)
        try container.encode(contentBlock, forKey: .contentBlock)
    }
}

public struct ClaudeContentBlockStopEvent: Codable, Sendable {
    public let type: String = "content_block_stop"
    public let index: Int

    enum CodingKeys: String, CodingKey {
        case type, index
    }

    public init(index: Int) {
        self.index = index
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "content_block_stop" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected content_block_stop event, got \(type)"
            )
        }
        self.index = try container.decode(Int.self, forKey: .index)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(index, forKey: .index)
    }
}

public struct ClaudeContentBlockDeltaEvent: Codable, Sendable {
    public let type: String = "content_block_delta"
    public let index: Int
    public let delta: ClaudeDelta

    enum CodingKeys: String, CodingKey {
        case type, index, delta
    }

    public init(index: Int, delta: ClaudeDelta) {
        self.index = index
        self.delta = delta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "content_block_delta" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected content_block_delta event, got \(type)"
            )
        }
        self.index = try container.decode(Int.self, forKey: .index)
        self.delta = try container.decode(ClaudeDelta.self, forKey: .delta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(index, forKey: .index)
        try container.encode(delta, forKey: .delta)
    }
}

public enum ClaudeDelta: Codable, Sendable {
    case text(ClaudeTextDelta)
    case inputJson(ClaudeInputJsonDelta)
    case thinking(ClaudeThinkingDelta)
    case signature(ClaudeSignatureDelta)
    case citations(ClaudeCitationsDelta)
    case unknown(ClaudeUnknownDelta)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text_delta":
            self = .text(try ClaudeTextDelta(from: decoder))
        case "input_json_delta":
            self = .inputJson(try ClaudeInputJsonDelta(from: decoder))
        case "thinking_delta":
            self = .thinking(try ClaudeThinkingDelta(from: decoder))
        case "signature_delta":
            self = .signature(try ClaudeSignatureDelta(from: decoder))
        case "citations_delta":
            self = .citations(try ClaudeCitationsDelta(from: decoder))
        default:
            self = .unknown(ClaudeUnknownDelta(type: type))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let delta):
            try delta.encode(to: encoder)
        case .inputJson(let delta):
            try delta.encode(to: encoder)
        case .thinking(let delta):
            try delta.encode(to: encoder)
        case .signature(let delta):
            try delta.encode(to: encoder)
        case .citations(let delta):
            try delta.encode(to: encoder)
        case .unknown(let delta):
            try delta.encode(to: encoder)
        }
    }
}

public struct ClaudeTextDelta: Codable, Sendable {
    public let type: String
    public let text: String

    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

public struct ClaudeInputJsonDelta: Codable, Sendable {
    public let type: String
    public let partialJson: String

    enum CodingKeys: String, CodingKey {
        case type
        case partialJson = "partial_json"
    }

    public init(type: String, partialJson: String) {
        self.type = type
        self.partialJson = partialJson
    }
}

public struct ClaudeThinkingDelta: Codable, Sendable {
    public let type: String
    public let thinking: String

    public init(type: String = "thinking_delta", thinking: String) {
        self.type = type
        self.thinking = thinking
    }
}

public struct ClaudeSignatureDelta: Codable, Sendable {
    public let type: String
    public let signature: String

    public init(type: String = "signature_delta", signature: String) {
        self.type = type
        self.signature = signature
    }
}

public struct ClaudeCitationsDelta: Codable, Sendable {
    public let type: String
    public let citation: AnyCodable?

    public init(type: String = "citations_delta", citation: AnyCodable? = nil) {
        self.type = type
        self.citation = citation
    }
}

public struct ClaudeUnknownDelta: Codable, Sendable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

public struct ClaudeMessageDeltaEvent: Codable, Sendable {
    public let type: String = "message_delta"
    public let delta: ClaudeMessageDeltaContent
    public let usage: ClaudeUsageDelta

    enum CodingKeys: String, CodingKey {
        case type, delta, usage
    }

    public init(delta: ClaudeMessageDeltaContent, usage: ClaudeUsageDelta) {
        self.delta = delta
        self.usage = usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "message_delta" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected message_delta event, got \(type)"
            )
        }
        self.delta = try container.decode(ClaudeMessageDeltaContent.self, forKey: .delta)
        self.usage = try container.decode(ClaudeUsageDelta.self, forKey: .usage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(delta, forKey: .delta)
        try container.encode(usage, forKey: .usage)
    }
}

public struct ClaudeMessageDeltaContent: Codable, Sendable {
    public let stopReason: String?
    public let stopSequence: String?

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }

    public init(stopReason: String?, stopSequence: String?) {
        self.stopReason = stopReason
        self.stopSequence = stopSequence
    }
}

public struct ClaudeUsageDelta: Codable, Sendable {
    public let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
    }

    public init(outputTokens: Int) {
        self.outputTokens = outputTokens
    }
}

// MARK: - Conversion Errors

public enum ConversionError: Error, LocalizedError {
    case noChoicesInResponse
    case invalidToolArguments(String)
    case unsupportedContentType(String)

    public var errorDescription: String? {
        switch self {
        case .noChoicesInResponse:
            return "OpenAI response contains no choices"
        case .invalidToolArguments(let msg):
            return "Invalid tool arguments: \(msg)"
        case .unsupportedContentType(let type):
            return "Unsupported content type: \(type)"
        }
    }
}
