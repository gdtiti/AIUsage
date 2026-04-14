import Foundation
import Network
import os.log
import QuotaBackend

extension QuotaHTTPServer {
    // MARK: - Claude Proxy Handlers

    func handleEventLoggingEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        httpLog.debug("→ POST /api/event_logging/batch")

        let batchId = UUID().uuidString
        var processedCount = 0

        // Parse request body
        if let loggingRequest = try? JSONDecoder().decode(EventLoggingBatchRequest.self, from: request.body) {
            let events = loggingRequest.events ?? []
            processedCount = events.count

            // Log first 5 events
            let previewCount = min(5, events.count)
            for (index, event) in events.prefix(previewCount).enumerated() {
                let eventType = event.eventType ?? "unknown"
                httpLog.debug("  Event \(index + 1): \(eventType)")
            }

            if events.count > previewCount {
                httpLog.debug("  ... and \(events.count - previewCount) more events")
            }
        }

        // Always return success (telemetry endpoint should never fail)
        let response = EventLoggingBatchResponse(
            success: true,
            batchId: batchId,
            processedCount: processedCount,
            message: "Batch received and logged"
        )

        return jsonResponse(encodable: response, headers: headers)
    }

    func handleMessagesEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        // Authenticate
        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        // Parse request
        guard let claudeRequest = try? JSONDecoder().decode(ClaudeMessageRequest.self, from: request.body) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse request body",
                status: 400,
                headers: headers
            )
        }

        httpLog.debug("→ POST /v1/messages (model: \(claudeRequest.model), stream: \(claudeRequest.stream ?? false))")

        let startTime = Date()
        do {
            let response = try await proxy.handleMessages(request: claudeRequest)
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                inputTokens: response.usage.inputTokens,
                outputTokens: response.usage.outputTokens,
                cacheTokens: (response.usage.cacheCreationInputTokens ?? 0) + (response.usage.cacheReadInputTokens ?? 0)
            )
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: error.localizedDescription
            )
            httpLog.error("  ✗ Proxy error: \(error.localizedDescription)")
            let errorResponse = await proxy.buildErrorResponse(error: error)
            return jsonResponse(encodable: errorResponse, status: 500, headers: headers)
        }
    }

    func handleCountTokensEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        // Authenticate
        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        // Parse request
        guard let tokenRequest = try? JSONDecoder().decode(ClaudeTokenCountRequest.self, from: request.body) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse token count request body",
                status: 400,
                headers: headers
            )
        }

        httpLog.debug("→ POST /v1/messages/count_tokens (model: \(tokenRequest.model))")

        do {
            // `input_tokens` in the body is a heuristic estimate from the proxy, not tokenizer-exact.
            let response = try await proxy.handleCountTokens(request: tokenRequest)
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            let errorResponse = await proxy.buildErrorResponse(error: error)
            return jsonResponse(encodable: errorResponse, status: 500, headers: headers)
        }
    }

    func handleStreamingProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let proxy = proxyService else {
            let response = claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        // Authenticate
        guard await proxy.authenticate(headers: request.headers) else {
            let response = claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        // Parse request
        guard let claudeRequest = try? JSONDecoder().decode(ClaudeMessageRequest.self, from: request.body) else {
            let response = claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse request body",
                status: 400,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        httpLog.debug("→ POST /v1/messages (streaming, model: \(claudeRequest.model))")

        let streamStartTime = Date()
        let streamer = StreamingResponse(connection: connection)

        // Send SSE headers
        await streamer.sendHeaders(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*"
        ])

        do {
            // Map model
            let upstreamModel = await proxy.mapModel(claudeRequest.model)

            // Convert request
            let converter = ClaudeToOpenAIConverter()
            let openAIRequest = try converter.convert(
                request: claudeRequest,
                upstreamModel: upstreamModel
            )

            // Get upstream client and send streaming request
            let (bytes, _) = try await proxy.sendStreamingRequest(openAIRequest: openAIRequest)

            let encoder = JSONEncoder()

            // Send message_start event
            let messageStart = ClaudeMessageStartEvent(
                message: ClaudeMessageStart(
                    id: "msg_\(UUID().uuidString.prefix(24))",
                    type: "message",
                    role: "assistant",
                    model: claudeRequest.model
                )
            )
            if let data = try? encoder.encode(messageStart),
               let json = String(data: data, encoding: .utf8) {
                await streamer.sendSSEEvent(event: "message_start", data: json)
            }

            // Send content_block_start for text
            let blockStart = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
            await streamer.sendSSEEvent(event: "content_block_start", data: blockStart)

            // Process upstream SSE chunks
            var currentLine = ""
            var outputTokens = 0
            var stopReason = "end_turn"

            for try await byte in bytes {
                let char = Character(UnicodeScalar(byte))
                if char == "\n" {
                    if currentLine.hasPrefix("data: ") {
                        let dataStr = String(currentLine.dropFirst(6))
                        if dataStr.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                            break
                        }

                        // Parse OpenAI chunk
                        if let chunkData = dataStr.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: chunkData),
                           let choice = chunk.choices.first {

                            // Handle text content delta
                            if let content = choice.delta.content, !content.isEmpty {
                                outputTokens += content.count / 4
                                let delta = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(escapeJSON(content))}}"
                                await streamer.sendSSEEvent(event: "content_block_delta", data: delta)
                            }

                            // Handle tool calls
                            if let toolCalls = choice.delta.toolCalls {
                                for toolCall in toolCalls {
                                    if let id = toolCall.id, let name = toolCall.function?.name {
                                        stopReason = "tool_use"
                                        let toolStart = "{\"type\":\"content_block_start\",\"index\":\(toolCall.index),\"content_block\":{\"type\":\"tool_use\",\"id\":\(escapeJSON(id)),\"name\":\(escapeJSON(name)),\"input\":{}}}"
                                        await streamer.sendSSEEvent(event: "content_block_start", data: toolStart)
                                    }
                                    if let args = toolCall.function?.arguments, !args.isEmpty {
                                        let toolDelta = "{\"type\":\"content_block_delta\",\"index\":\(toolCall.index),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(escapeJSON(args))}}"
                                        await streamer.sendSSEEvent(event: "content_block_delta", data: toolDelta)
                                    }
                                }
                            }

                            // Handle finish reason
                            if let finish = choice.finishReason {
                                switch finish {
                                case "tool_calls": stopReason = "tool_use"
                                case "stop": stopReason = "end_turn"
                                case "length": stopReason = "max_tokens"
                                default: break
                                }
                            }
                        }
                    }
                    currentLine = ""
                } else {
                    currentLine.append(char)
                }
            }

            // Send content_block_stop
            let blockStop = "{\"type\":\"content_block_stop\",\"index\":0}"
            await streamer.sendSSEEvent(event: "content_block_stop", data: blockStop)

            // Send message_delta
            let messageDelta = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":\(max(1, outputTokens))}}"
            await streamer.sendSSEEvent(event: "message_delta", data: messageDelta)

            // Send message_stop
            await streamer.sendSSEEvent(event: "message_stop", data: "{\"type\":\"message_stop\"}")

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                outputTokens: max(1, outputTokens)
            )

        } catch {
            httpLog.error("  ✗ Streaming proxy error: \(error.localizedDescription)")
            let errMsg = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\(escapeJSON(error.localizedDescription))}}"
            await streamer.sendSSEEvent(event: "error", data: errMsg)

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let errUpstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: errUpstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: error.localizedDescription
            )
        }

        streamer.close()
    }

    func emitRequestLog(
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheTokens: Int = 0,
        errorMessage: String? = nil
    ) {
        var parts = [
            "\"type\":\"proxy_request_log\"",
            "\"claude_model\":\(escapeJSON(claudeModel))",
            "\"upstream_model\":\(escapeJSON(upstreamModel))",
            "\"success\":\(success)",
            "\"response_time_ms\":\(Int(responseTimeMs))",
            "\"input_tokens\":\(inputTokens)",
            "\"output_tokens\":\(outputTokens)",
            "\"cache_tokens\":\(cacheTokens)"
        ]
        if let err = errorMessage {
            parts.append("\"error\":\(escapeJSON(err))")
        }
        print("PROXY_LOG:{\(parts.joined(separator: ","))}")
    }
}
