import Foundation

// MARK: - Claude API Request Models

public struct ClaudeMessageRequest: Codable, Sendable {
    public let model: String
    public let messages: [ClaudeMessage]
    public let system: String?
    public let maxTokens: Int
    public let temperature: Double?
    public let topP: Double?
    public let topK: Int?
    public let stopSequences: [String]?
    public let stream: Bool?
    public let tools: [ClaudeTool]?
    public let toolChoice: ClaudeToolChoice?
    public let metadata: ClaudeMetadata?

    enum CodingKeys: String, CodingKey {
        case model, messages, system, temperature, tools, metadata, stream
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case stopSequences = "stop_sequences"
        case toolChoice = "tool_choice"
    }

    public init(
        model: String,
        messages: [ClaudeMessage],
        system: String? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stopSequences: [String]? = nil,
        stream: Bool? = nil,
        tools: [ClaudeTool]? = nil,
        toolChoice: ClaudeToolChoice? = nil,
        metadata: ClaudeMetadata? = nil
    ) {
        self.model = model
        self.messages = messages
        self.system = system
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([ClaudeMessage].self, forKey: .messages)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)
        stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        tools = try container.decodeIfPresent([ClaudeTool].self, forKey: .tools)
        toolChoice = try container.decodeIfPresent(ClaudeToolChoice.self, forKey: .toolChoice)
        metadata = try container.decodeIfPresent(ClaudeMetadata.self, forKey: .metadata)

        // system can be a string or an array of {type, text, ...} blocks
        if let text = try? container.decodeIfPresent(String.self, forKey: .system) {
            system = text
        } else if let blocks = try? container.decodeIfPresent([SystemBlock].self, forKey: .system) {
            system = blocks.compactMap { $0.text }.joined(separator: "\n")
        } else {
            system = nil
        }
    }

    private struct SystemBlock: Codable {
        let type: String?
        let text: String?
    }
}

public struct ClaudeMessage: Codable, Sendable {
    public let role: String
    public let content: ClaudeContent

    public init(role: String, content: ClaudeContent) {
        self.role = role
        self.content = content
    }
}

public enum ClaudeContent: Codable, Sendable {
    case text(String)
    case blocks([ClaudeContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([ClaudeContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Content must be string or array of blocks"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

public enum ClaudeContentBlock: Codable, Sendable {
    case text(ClaudeTextBlock)
    case image(ClaudeImageBlock)
    case toolUse(ClaudeToolUseBlock)
    case toolResult(ClaudeToolResultBlock)
    case unknown(String)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try ClaudeTextBlock(from: decoder))
        case "image":
            self = .image(try ClaudeImageBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ClaudeToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try ClaudeToolResultBlock(from: decoder))
        default:
            self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .image(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        case .unknown:
            break
        }
    }
}

public struct ClaudeTextBlock: Codable, Sendable {
    public let type: String
    public let text: String

    enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(text: String) {
        self.type = "text"
        self.text = text
    }
}

public struct ClaudeImageBlock: Codable, Sendable {
    public let type: String
    public let source: ClaudeImageSource

    enum CodingKeys: String, CodingKey {
        case type, source
    }

    public init(source: ClaudeImageSource) {
        self.type = "image"
        self.source = source
    }
}

public struct ClaudeImageSource: Codable, Sendable {
    public let type: String
    public let mediaType: String
    public let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }

    public init(type: String = "base64", mediaType: String, data: String) {
        self.type = type
        self.mediaType = mediaType
        self.data = data
    }
}

public struct ClaudeToolUseBlock: Codable, Sendable {
    public let type: String
    public let id: String
    public let name: String
    public let input: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type, id, name, input
    }

    public init(id: String, name: String, input: [String: AnyCodable]) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ClaudeToolResultBlock: Codable, Sendable {
    public let type: String
    public let toolUseId: String
    public let content: String?
    public let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    public init(toolUseId: String, content: String?, isError: Bool? = nil) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        toolUseId = try container.decode(String.self, forKey: .toolUseId)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)

        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
        } else if let blocks = try? container.decodeIfPresent([ToolResultContentBlock].self, forKey: .content) {
            content = blocks.compactMap { $0.text }.joined(separator: "\n")
        } else {
            content = nil
        }
    }

    private struct ToolResultContentBlock: Codable {
        let type: String?
        let text: String?
    }
}

public struct ClaudeTool: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }

    public init(name: String, description: String?, inputSchema: [String: AnyCodable]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ClaudeToolChoice: Codable, Sendable {
    public let type: String
    public let name: String?

    public init(type: String, name: String? = nil) {
        self.type = type
        self.name = name
    }
}

public struct ClaudeMetadata: Codable, Sendable {
    public let userId: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }

    public init(userId: String?) {
        self.userId = userId
    }
}

// MARK: - Claude API Response Models

public struct ClaudeMessageResponse: Codable, Sendable {
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
        type: String = "message",
        role: String,
        content: [ClaudeContentBlock],
        model: String,
        stopReason: String?,
        stopSequence: String?,
        usage: ClaudeUsage
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

public struct ClaudeUsage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

// MARK: - Claude Token Count Request/Response

public struct ClaudeTokenCountRequest: Codable, Sendable {
    public let model: String
    public let messages: [ClaudeMessage]
    public let system: String?
    public let tools: [ClaudeTool]?

    public init(model: String, messages: [ClaudeMessage], system: String?, tools: [ClaudeTool]?) {
        self.model = model
        self.messages = messages
        self.system = system
        self.tools = tools
    }
}

public struct ClaudeTokenCountResponse: Codable, Sendable {
    public let inputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
    }

    public init(inputTokens: Int) {
        self.inputTokens = inputTokens
    }
}

// MARK: - Claude Error Response

public struct ClaudeErrorResponse: Codable, Sendable {
    public let type: String
    public let error: ClaudeError

    public init(type: String = "error", error: ClaudeError) {
        self.type = type
        self.error = error
    }
}

public struct ClaudeError: Codable, Sendable {
    public let type: String
    public let message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}
