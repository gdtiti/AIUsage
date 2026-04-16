import Foundation

public enum CanonicalLossySeverity: Sendable {
    case info
    case warning
    case error

    public var value: String {
        switch self {
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }
}

public struct CanonicalLossyNote: Sendable {
    public let code: String
    public let message: String
    public let severity: CanonicalLossySeverity
    public let itemIndex: Int?
    public let path: String?
    public let rawExtensions: [CanonicalVendorExtension]

    public init(
        code: String,
        message: String,
        severity: CanonicalLossySeverity = .warning,
        itemIndex: Int? = nil,
        path: String? = nil,
        rawExtensions: [CanonicalVendorExtension] = []
    ) {
        self.code = code
        self.message = message
        self.severity = severity
        self.itemIndex = itemIndex
        self.path = path
        self.rawExtensions = rawExtensions
    }
}

public struct CanonicalBuildResult<Payload: Sendable>: Sendable {
    public let payload: Payload
    public let lossyNotes: [CanonicalLossyNote]

    public init(payload: Payload, lossyNotes: [CanonicalLossyNote] = []) {
        self.payload = payload
        self.lossyNotes = lossyNotes
    }
}
