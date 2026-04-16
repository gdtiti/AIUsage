import Foundation

public enum CanonicalStreamEvent: Sendable {
    case messageStarted(CanonicalStreamMessageStarted)
    case contentPartStarted(CanonicalStreamContentPartStarted)
    case contentPartDelta(CanonicalStreamContentPartDelta)
    case contentPartStopped(CanonicalStreamContentPartStopped)
    case messageDelta(CanonicalStreamMessageDelta)
    case messageStopped
    case error(CanonicalStreamError)
}

public enum CanonicalStreamPartKind: Sendable {
    case text
    case reasoning
    case toolCall
    case unknown(String)

    public var value: String {
        switch self {
        case .text: return "text"
        case .reasoning: return "reasoning"
        case .toolCall: return "tool_call"
        case .unknown(let raw): return raw
        }
    }
}

public struct CanonicalStreamMessageStarted: Sendable {
    public let role: CanonicalRole
    public let messageID: String?
    public let model: String?
    public let rawExtensions: [CanonicalVendorExtension]

    public init(
        role: CanonicalRole,
        messageID: String? = nil,
        model: String? = nil,
        rawExtensions: [CanonicalVendorExtension] = []
    ) {
        self.role = role
        self.messageID = messageID
        self.model = model
        self.rawExtensions = rawExtensions
    }
}

public struct CanonicalStreamContentPartStarted: Sendable {
    public let index: Int
    public let kind: CanonicalStreamPartKind
    public let toolCallID: String?
    public let toolName: String?
    public let rawExtensions: [CanonicalVendorExtension]

    public init(
        index: Int,
        kind: CanonicalStreamPartKind,
        toolCallID: String? = nil,
        toolName: String? = nil,
        rawExtensions: [CanonicalVendorExtension] = []
    ) {
        self.index = index
        self.kind = kind
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.rawExtensions = rawExtensions
    }
}

public struct CanonicalStreamContentPartDelta: Sendable {
    public let index: Int
    public let kind: CanonicalStreamPartKind
    public let textDelta: String?
    public let jsonDelta: String?
    public let rawExtensions: [CanonicalVendorExtension]

    public init(
        index: Int,
        kind: CanonicalStreamPartKind,
        textDelta: String? = nil,
        jsonDelta: String? = nil,
        rawExtensions: [CanonicalVendorExtension] = []
    ) {
        self.index = index
        self.kind = kind
        self.textDelta = textDelta
        self.jsonDelta = jsonDelta
        self.rawExtensions = rawExtensions
    }
}

public struct CanonicalStreamContentPartStopped: Sendable {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }
}

public struct CanonicalStreamMessageDelta: Sendable {
    public let stop: CanonicalStop?
    public let usage: CanonicalUsage?
    public let rawExtensions: [CanonicalVendorExtension]

    public init(
        stop: CanonicalStop? = nil,
        usage: CanonicalUsage? = nil,
        rawExtensions: [CanonicalVendorExtension] = []
    ) {
        self.stop = stop
        self.usage = usage
        self.rawExtensions = rawExtensions
    }
}

public struct CanonicalStreamError: Sendable {
    public let message: String
    public let rawExtensions: [CanonicalVendorExtension]

    public init(message: String, rawExtensions: [CanonicalVendorExtension] = []) {
        self.message = message
        self.rawExtensions = rawExtensions
    }
}
