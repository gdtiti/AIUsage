import Foundation

// MARK: - Event Logging Models

public struct EventLoggingBatchRequest: Codable, Sendable {
    public let batchId: String?
    public let events: [EventLog]?

    enum CodingKeys: String, CodingKey {
        case batchId = "batch_id"
        case events
    }

    public init(batchId: String? = nil, events: [EventLog]? = nil) {
        self.batchId = batchId
        self.events = events
    }
}

public struct EventLog: Codable, Sendable {
    public let eventType: String?
    public let timestamp: String?
    public let data: [String: String]?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case timestamp
        case data
    }

    public init(eventType: String?, timestamp: String? = nil, data: [String: String]? = nil) {
        self.eventType = eventType
        self.timestamp = timestamp
        self.data = data
    }
}

public struct EventLoggingBatchResponse: Codable, Sendable {
    public let success: Bool
    public let batchId: String
    public let processedCount: Int
    public let message: String

    enum CodingKeys: String, CodingKey {
        case success
        case batchId = "batch_id"
        case processedCount = "processed_count"
        case message
    }

    public init(success: Bool, batchId: String, processedCount: Int, message: String) {
        self.success = success
        self.batchId = batchId
        self.processedCount = processedCount
        self.message = message
    }
}
