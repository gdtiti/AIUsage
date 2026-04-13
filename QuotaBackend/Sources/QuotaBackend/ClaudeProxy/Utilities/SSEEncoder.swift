import Foundation

// MARK: - SSE Encoder

public struct SSEEncoder {

    public init() {}

    /// Format an SSE event with event type and JSON data
    public func encode(event: String?, data: String) -> String {
        var message = ""
        if let event {
            message += "event: \(event)\n"
        }
        message += "data: \(data)\n\n"
        return message
    }

    /// Encode a Codable object as an SSE event
    public func encode<T: Encodable>(event: String?, object: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return encode(event: event, data: json)
    }

    /// Build a complete Anthropic SSE message_start event
    public func messageStartEvent(
        id: String,
        model: String,
        inputTokens: Int = 0
    ) -> String {
        let data = """
        {"type":"message_start","message":{"id":"\(id)","type":"message","role":"assistant","content":[],"model":"\(model)","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":\(inputTokens),"output_tokens":0}}}
        """
        return encode(event: "message_start", data: data)
    }

    /// Build a text content_block_start event
    public func textBlockStartEvent(index: Int) -> String {
        let data = """
        {"type":"content_block_start","index":\(index),"content_block":{"type":"text","text":""}}
        """
        return encode(event: "content_block_start", data: data)
    }

    /// Build a text content_block_delta event
    public func textDeltaEvent(index: Int, text: String) -> String {
        let escapedText = escapeJSON(text)
        let data = """
        {"type":"content_block_delta","index":\(index),"delta":{"type":"text_delta","text":\(escapedText)}}
        """
        return encode(event: "content_block_delta", data: data)
    }

    /// Build a content_block_stop event
    public func blockStopEvent(index: Int) -> String {
        let data = """
        {"type":"content_block_stop","index":\(index)}
        """
        return encode(event: "content_block_stop", data: data)
    }

    /// Build a message_delta event
    public func messageDeltaEvent(stopReason: String, outputTokens: Int) -> String {
        let data = """
        {"type":"message_delta","delta":{"stop_reason":"\(stopReason)","stop_sequence":null},"usage":{"output_tokens":\(outputTokens)}}
        """
        return encode(event: "message_delta", data: data)
    }

    /// Build a message_stop event
    public func messageStopEvent() -> String {
        return encode(event: "message_stop", data: "{\"type\":\"message_stop\"}")
    }

    /// Build a ping event
    public func pingEvent() -> String {
        return encode(event: "ping", data: "{\"type\":\"ping\"}")
    }

    /// Build a tool_use content_block_start event
    public func toolUseBlockStartEvent(index: Int, id: String, name: String) -> String {
        let data = """
        {"type":"content_block_start","index":\(index),"content_block":{"type":"tool_use","id":\(escapeJSON(id)),"name":\(escapeJSON(name)),"input":{}}}
        """
        return encode(event: "content_block_start", data: data)
    }

    /// Build an input_json_delta event for tool use
    public func inputJsonDeltaEvent(index: Int, partialJson: String) -> String {
        let data = """
        {"type":"content_block_delta","index":\(index),"delta":{"type":"input_json_delta","partial_json":\(escapeJSON(partialJson))}}
        """
        return encode(event: "content_block_delta", data: data)
    }

    // MARK: - Private Helpers

    private func escapeJSON(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\(string)\""
        }
        return json
    }
}
