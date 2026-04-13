import Foundation

// MARK: - OpenAI API Request Models

public struct OpenAIChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [OpenAIChatMessage]
    public let temperature: Double?
    public let topP: Double?
    public let maxTokens: Int?
    public let stop: [String]?
    public let stream: Bool?
    public let tools: [OpenAITool]?
    public let toolChoice: OpenAIToolChoice?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stop, stream, tools
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
    }

    public init(
        model: String,
        messages: [OpenAIChatMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stop: [String]? = nil,
        stream: Bool? = nil,
        tools: [OpenAITool]? = nil,
        toolChoice: OpenAIToolChoice? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stop = stop
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

public struct OpenAIChatMessage: Codable, Sendable {
    public let role: String
    public let content: OpenAIMessageContent?
    public let name: String?
    public let toolCalls: [OpenAIToolCall]?
    public let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public init(
        role: String,
        content: OpenAIMessageContent? = nil,
        name: String? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

public enum OpenAIMessageContent: Codable, Sendable {
    case text(String)
    case parts([OpenAIContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let parts = try? container.decode([OpenAIContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Content must be string or array of parts"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

public enum OpenAIContentPart: Codable, Sendable {
    case text(OpenAITextPart)
    case imageUrl(OpenAIImageUrlPart)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try OpenAITextPart(from: decoder))
        case "image_url":
            self = .imageUrl(try OpenAIImageUrlPart(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content part type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let part):
            try part.encode(to: encoder)
        case .imageUrl(let part):
            try part.encode(to: encoder)
        }
    }
}

public struct OpenAITextPart: Codable, Sendable {
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

public struct OpenAIImageUrlPart: Codable, Sendable {
    public let type: String
    public let imageUrl: OpenAIImageUrl

    enum CodingKeys: String, CodingKey {
        case type
        case imageUrl = "image_url"
    }

    public init(imageUrl: OpenAIImageUrl) {
        self.type = "image_url"
        self.imageUrl = imageUrl
    }
}

public struct OpenAIImageUrl: Codable, Sendable {
    public let url: String
    public let detail: String?

    public init(url: String, detail: String? = nil) {
        self.url = url
        self.detail = detail
    }
}

public struct OpenAIToolCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let function: OpenAIFunctionCall

    public init(id: String, type: String = "function", function: OpenAIFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunctionCall: Codable, Sendable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct OpenAITool: Codable, Sendable {
    public let type: String
    public let function: OpenAIFunction

    public init(type: String = "function", function: OpenAIFunction) {
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunction: Codable, Sendable {
    public let name: String
    public let description: String?
    public let parameters: [String: AnyCodable]?

    public init(name: String, description: String?, parameters: [String: AnyCodable]?) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum OpenAIToolChoice: Codable, Sendable {
    case none
    case auto
    case required
    case function(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            switch str {
            case "none": self = .none
            case "auto": self = .auto
            case "required": self = .required
            default: self = .auto
            }
        } else {
            self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode("none")
        case .auto:
            try container.encode("auto")
        case .required:
            try container.encode("required")
        case .function(let name):
            let obj: [String: Any] = ["type": "function", "function": ["name": name]]
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                try container.encode(dict)
            }
        }
    }
}

// MARK: - OpenAI API Response Models

public struct OpenAIChatCompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [OpenAIChoice]
    public let usage: OpenAIUsage?

    public init(
        id: String,
        object: String = "chat.completion",
        created: Int,
        model: String,
        choices: [OpenAIChoice],
        usage: OpenAIUsage?
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

public struct OpenAIChoice: Codable, Sendable {
    public let index: Int
    public let message: OpenAIChatMessage
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }

    public init(index: Int, message: OpenAIChatMessage, finishReason: String?) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }
}

public struct OpenAIUsage: Codable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

// MARK: - OpenAI Streaming Response Models

public struct OpenAIStreamChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [OpenAIStreamChoice]

    public init(id: String, object: String = "chat.completion.chunk", created: Int, model: String, choices: [OpenAIStreamChoice]) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
    }
}

public struct OpenAIStreamChoice: Codable, Sendable {
    public let index: Int
    public let delta: OpenAIDelta
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }

    public init(index: Int, delta: OpenAIDelta, finishReason: String?) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }
}

public struct OpenAIDelta: Codable, Sendable {
    public let role: String?
    public let content: String?
    public let toolCalls: [OpenAIToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }

    public init(role: String? = nil, content: String? = nil, toolCalls: [OpenAIToolCallDelta]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }
}

public struct OpenAIToolCallDelta: Codable, Sendable {
    public let index: Int
    public let id: String?
    public let type: String?
    public let function: OpenAIFunctionDelta?

    public init(index: Int, id: String?, type: String?, function: OpenAIFunctionDelta?) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunctionDelta: Codable, Sendable {
    public let name: String?
    public let arguments: String?

    public init(name: String?, arguments: String?) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - OpenAI Error Response

public struct OpenAIErrorResponse: Codable, Sendable {
    public let error: OpenAIError

    public init(error: OpenAIError) {
        self.error = error
    }
}

public struct OpenAIError: Codable, Sendable {
    public let message: String
    public let type: String?
    public let code: String?

    public init(message: String, type: String?, code: String?) {
        self.message = message
        self.type = type
        self.code = code
    }
}
