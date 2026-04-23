import Foundation
import Network
import os.log
import QuotaBackend

extension QuotaHTTPServer {
    // MARK: - Anthropic Passthrough Proxy

    func handlePassthroughProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let config = proxyConfig else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Passthrough not configured\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        if let expectedKey = config.expectedClientKey, !expectedKey.isEmpty {
            let clientKey = request.headers["x-api-key"] ?? request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
            if clientKey != expectedKey {
                let resp = claudeErrorResponse(type: "authentication_error", message: "Invalid API key", status: 401, headers: [:])
                await sendResponse(connection, response: resp)
                connection.cancel()
                return
            }
        }

        let startTime = Date()
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryPart = request.path.contains("?") ? "?" + request.path.split(separator: "?").dropFirst().joined(separator: "?") : ""
        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + String(cleanPath.dropFirst()) + queryPart
            : config.upstreamBaseURL + cleanPath + queryPart

        httpLog.debug("→ PASSTHROUGH \(request.method) \(request.path, privacy: .public) → \(upstreamURL, privacy: .private)")

        guard let url = URL(string: upstreamURL) else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid upstream URL\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        var mutableBody = request.body
        var mutableHeaders = request.headers
        if let interceptor = config.interceptor {
            let _ = interceptor.intercept(
                path: cleanPath,
                headers: &mutableHeaders,
                body: &mutableBody
            )
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = mutableBody

        for (key, value) in mutableHeaders {
            let lk = key.lowercased()
            if lk == "host" || lk == "content-length" { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }
        if mutableHeaders["content-type"] == nil {
            upstreamReq.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let isStreaming: Bool
        let requestModel: String
        if let json = try? JSONSerialization.jsonObject(with: mutableBody) as? [String: Any] {
            isStreaming = json["stream"] as? Bool ?? false
            requestModel = json["model"] as? String ?? "unknown"
        } else {
            isStreaming = false
            requestModel = "unknown"
        }

        if isStreaming {
            await handlePassthroughStreaming(connection, upstreamRequest: upstreamReq, requestModel: requestModel, startTime: startTime)
        } else {
            await handlePassthroughNonStreaming(connection, upstreamRequest: upstreamReq, requestModel: requestModel, startTime: startTime)
        }
    }

    func handlePassthroughNonStreaming(_ connection: NWConnection, upstreamRequest: URLRequest, requestModel: String, startTime: Date) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            var respHeaders: [String: String] = ["Content-Type": "application/json"]
            httpResp?.allHeaderFields.forEach { key, value in
                if let k = key as? String, let v = value as? String {
                    let lk = k.lowercased()
                    if lk != "content-length" && lk != "transfer-encoding" {
                        respHeaders[k] = v
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let usage = json["usage"] as? [String: Any] {
                emitPassthroughLog(model: requestModel, usage: usage, responseTimeMs: Int(elapsed), success: statusCode < 400)
            }

            let resp = HTTPResponse(status: statusCode, headers: respHeaders, bodyData: data)
            await sendResponse(connection, response: resp)
            connection.cancel()
        } catch {
            let escaped = escapeJSON("Upstream error: \(error.localizedDescription)")
            let resp = HTTPResponse(status: 502, headers: ["Content-Type": "application/json"], body: "{\"error\":\(escaped)}")
            await sendResponse(connection, response: resp)
            connection.cancel()
        }
    }

    func handlePassthroughStreaming(_ connection: NWConnection, upstreamRequest: URLRequest, requestModel: String, startTime: Date) async {
        let streamer = StreamingResponse(connection: connection)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            var respHeaders: [String: String] = [
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            ]
            httpResp?.allHeaderFields.forEach { key, value in
                guard let k = key as? String, let v = value as? String else { return }
                let lk = k.lowercased()
                if lk != "content-length" && lk != "transfer-encoding" && lk != "connection" {
                    respHeaders[k] = v
                }
            }
            if respHeaders["Content-Type"] == nil && respHeaders["content-type"] == nil {
                respHeaders["Content-Type"] = "text/event-stream"
            }
            await streamer.sendHeaders(status: statusCode, headers: respHeaders)

            var totalInputTokens = 0
            var totalOutputTokens = 0
            var cacheCreationTokens = 0
            var cacheReadTokens = 0
            var lineBuffer = Data()

            func processUsageLine(_ line: String) {
                guard line.hasPrefix("data: "), let jsonStart = line.firstIndex(of: Character("{")) else {
                    return
                }
                let jsonStr = String(line[jsonStart...])
                guard let eventData = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any],
                      let usage = eventData["usage"] as? [String: Any] else {
                    return
                }
                if let v = usage["input_tokens"] as? Int { totalInputTokens = v }
                if let v = usage["output_tokens"] as? Int { totalOutputTokens = v }
                if let v = usage["cache_creation_input_tokens"] as? Int { cacheCreationTokens = v }
                if let v = usage["cache_read_input_tokens"] as? Int { cacheReadTokens = v }
            }

            for try await byte in bytes {
                lineBuffer.append(byte)

                if byte == 0x0A {
                    // Forward each line immediately for real-time SSE delivery
                    await streamer.sendDataChunk(lineBuffer)

                    var trimmed = lineBuffer
                    if trimmed.last == 0x0A { trimmed.removeLast() }
                    if trimmed.last == 0x0D { trimmed.removeLast() }
                    let line = String(decoding: trimmed, as: UTF8.self)
                    processUsageLine(line)

                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }

            if !lineBuffer.isEmpty {
                let trailingLine = String(decoding: lineBuffer, as: UTF8.self)
                processUsageLine(trailingLine)
                await streamer.sendDataChunk(lineBuffer)
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let usageDict: [String: Any] = [
                "input_tokens": totalInputTokens,
                "output_tokens": totalOutputTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
                "cache_read_input_tokens": cacheReadTokens
            ]
            emitPassthroughLog(model: requestModel, usage: usageDict, responseTimeMs: Int(elapsed), success: statusCode < 400)

            await streamer.finish()
        } catch {
            let escaped = escapeJSON(error.localizedDescription)
            await streamer.sendChunk("event: error\ndata: {\"error\":\(escaped)}\n\n")
            await streamer.finish()
        }
    }

    func forwardPassthrough(request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let config = proxyConfig else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Not configured\"}")
        }

        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + String(path.dropFirst())
            : config.upstreamBaseURL + path

        guard let url = URL(string: upstreamURL) else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid URL\"}")
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = request.body
        for (key, value) in request.headers {
            let lk = key.lowercased()
            if lk == "host" || lk == "content-length" { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamReq)
            let httpResp = response as? HTTPURLResponse
            return HTTPResponse(
                status: httpResp?.statusCode ?? 502,
                headers: ["Content-Type": "application/json"],
                bodyData: data
            )
        } catch {
            let escaped = escapeJSON(error.localizedDescription)
            return HTTPResponse(status: 502, headers: ["Content-Type": "application/json"], body: "{\"error\":\(escaped)}")
        }
    }

    func emitPassthroughLog(model: String, usage: [String: Any], responseTimeMs: Int, success: Bool) {
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

        let log: [String: Any] = [
            "type": "proxy_request_log",
            "claude_model": model,
            "upstream_model": model,
            "success": success,
            "response_time_ms": responseTimeMs,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cache_creation_tokens": cacheCreation,
            "cache_read_tokens": cacheRead,
            "cache_tokens": cacheCreation + cacheRead,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: log),
           let jsonStr = String(data: data, encoding: .utf8) {
            // stdout is parsed by the macOS host app for structured log ingestion
            print("PROXY_LOG:\(jsonStr)")
        }
    }
}
