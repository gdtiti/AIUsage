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
            ? config.upstreamBaseURL + cleanPath.dropFirst() + queryPart
            : config.upstreamBaseURL + cleanPath + queryPart

        httpLog.debug("→ PASSTHROUGH \(request.method) \(request.path, privacy: .public) → \(upstreamURL, privacy: .private)")

        guard let url = URL(string: upstreamURL) else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid upstream URL\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
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
        upstreamReq.setValue("application/json", forHTTPHeaderField: "content-type")

        let isStreaming: Bool
        let requestModel: String
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
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

            let responseStr = String(data: data, encoding: .utf8) ?? ""
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

            let resp = HTTPResponse(status: statusCode, headers: respHeaders, body: responseStr)
            await sendResponse(connection, response: resp)
            connection.cancel()
        } catch {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Upstream error: \(error.localizedDescription)\"}")
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

            await streamer.sendHeaders(status: statusCode, headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive"
            ])

            var totalInputTokens = 0
            var totalOutputTokens = 0
            var cacheCreationTokens = 0
            var cacheReadTokens = 0

            for try await line in bytes.lines {
                await streamer.sendChunk(line + "\n")

                if line.hasPrefix("data: "), let jsonStart = line.firstIndex(of: Character("{")) {
                    let jsonStr = String(line[jsonStart...])
                    if let eventData = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any] {
                        if let usage = eventData["usage"] as? [String: Any] {
                            if let v = usage["input_tokens"] as? Int { totalInputTokens = v }
                            if let v = usage["output_tokens"] as? Int { totalOutputTokens = v }
                            if let v = usage["cache_creation_input_tokens"] as? Int { cacheCreationTokens = v }
                            if let v = usage["cache_read_input_tokens"] as? Int { cacheReadTokens = v }
                        }
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let usageDict: [String: Any] = [
                "input_tokens": totalInputTokens,
                "output_tokens": totalOutputTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
                "cache_read_input_tokens": cacheReadTokens
            ]
            emitPassthroughLog(model: requestModel, usage: usageDict, responseTimeMs: Int(elapsed), success: statusCode < 400)

            streamer.close()
        } catch {
            await streamer.sendChunk("event: error\ndata: {\"error\":\"\(error.localizedDescription)\"}\n\n")
            streamer.close()
        }
    }

    func forwardPassthrough(request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let config = proxyConfig else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Not configured\"}")
        }

        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + path.dropFirst()
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
                body: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"\(error.localizedDescription)\"}")
        }
    }

    func emitPassthroughLog(model: String, usage: [String: Any], responseTimeMs: Int, success: Bool) {
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheTokens = cacheCreation + cacheRead

        let log: [String: Any] = [
            "type": "proxy_request_log",
            "claude_model": model,
            "upstream_model": model,
            "success": success,
            "response_time_ms": responseTimeMs,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cache_tokens": cacheTokens,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: log),
           let jsonStr = String(data: data, encoding: .utf8) {
            print("PROXY_LOG:\(jsonStr)")
        }
    }
}
