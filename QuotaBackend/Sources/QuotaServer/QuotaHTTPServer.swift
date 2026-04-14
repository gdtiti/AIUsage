import Foundation
import Network
import os.log
import QuotaBackend

let httpLog = Logger(subsystem: "com.aiusage.quotaserver", category: "HTTP")

enum QuotaHTTPServerError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid server port \(port). Use a value from 1 through 65535."
        }
    }
}

// MARK: - Lightweight HTTP Server
// Uses Network.framework (no external dependencies) to serve the same JSON API
// as the original Node.js backend.

public final class QuotaHTTPServer: @unchecked Sendable {
    let host: String
    let port: Int
    let engine = ProviderEngine()
    var proxyService: ClaudeProxyService?
    var proxyConfig: ClaudeProxyConfiguration?

    var isPassthrough: Bool { proxyConfig?.mode == .anthropicPassthrough }

    public init(host: String, port: Int, proxyConfig: ClaudeProxyConfiguration? = nil) {
        self.host = host
        self.port = port
        self.proxyConfig = proxyConfig
        if let config = proxyConfig, config.enabled, config.mode == .openaiConvert {
            self.proxyService = try? ClaudeProxyService(configuration: config)
        }
    }

    public func run() async throws {
        guard (1...65_535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw QuotaHTTPServerError.invalidPort(port)
        }
        let nwHost = NWEndpoint.Host(host)

        // Create IPv4 listener with explicit local endpoint
        let params4 = NWParameters.tcp
        params4.requiredLocalEndpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
        let listener4 = try NWListener(using: params4)
        listener4.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }
        listener4.start(queue: .global())

        // Attempt IPv6 dual-stack (best-effort, may fail if IPv4 already covers it)
        var ipv6Active = false
        do {
            let params6 = NWParameters.tcp
            params6.requiredLocalEndpoint = NWEndpoint.hostPort(host: "::1", port: nwPort)
            let listener6 = try NWListener(using: params6)
            listener6.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handleConnection(connection) }
            }
            listener6.stateUpdateHandler = { state in
                if case .failed(_) = state {
                    // IPv6 bind failed — IPv4 on 0.0.0.0 typically already covers dual-stack
                }
            }
            listener6.start(queue: .global())
            ipv6Active = true
        } catch {
            // Silently ignore — IPv4 on 0.0.0.0 handles most cases
        }

        httpLog.info("QuotaServer listening on \(self.host):\(self.port)\(ipv6Active ? " (IPv4 + IPv6)" : " (IPv4)")")
        httpLog.info("Endpoints:")
        httpLog.info("  GET /api/dashboard")
        httpLog.info("  GET /api/provider/:id")
        httpLog.info("  GET /api/providers")
        httpLog.info("  GET /api/health")
        httpLog.info("  GET /health")
        if self.proxyService != nil {
            httpLog.info("  POST /v1/messages (Claude Proxy - OpenAI Convert)")
            httpLog.info("  POST /v1/messages/count_tokens (Claude Proxy)")
        }
        if self.isPassthrough {
            httpLog.info("  POST /v1/messages (Anthropic Passthrough)")
        }

        // Keep alive until IPv4 listener fails
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listener4.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    httpLog.error("Listener failed: \(error.localizedDescription)")
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        guard let requestData = await receiveData(connection) else {
            connection.cancel()
            return
        }

        let request = parseHTTPRequest(requestData)
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path

        if request.method == "POST",
           cleanPath == "/v1/messages" || cleanPath.hasPrefix("/v1/messages/") {
            if isPassthrough {
                await handlePassthroughProxy(connection, request: request)
                return
            }
            if proxyService != nil {
                let isStreaming: Bool
                if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                    isStreaming = json["stream"] as? Bool ?? false
                } else {
                    isStreaming = false
                }
                if isStreaming {
                    await handleStreamingProxy(connection, request: request)
                    return
                }
            }
        }

        let response = await routeRequest(request)
        await sendResponse(connection, response: response)
        connection.cancel()
    }

    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryItems = parseQueryItems(request.path)
        let corsHeaders = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type"
        ]

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: corsHeaders, body: "")
        }

        switch (request.method, path) {
        case ("GET", "/health"), ("GET", "/api/health"):
            let generatedAt = SharedFormatters.iso8601String(from: Date())
            return jsonResponse(
                [
                    "ok": true,
                    "generatedAt": generatedAt
                ],
                headers: corsHeaders
            )

        // MARK: - Claude Proxy Endpoints

        case ("POST", "/v1/messages"):
            return await handleMessagesEndpoint(request: request, headers: corsHeaders)

        case ("POST", "/v1/messages/count_tokens"):
            return await handleCountTokensEndpoint(request: request, headers: corsHeaders)

        case ("POST", "/api/event_logging/batch"):
            if isPassthrough {
                return await forwardPassthrough(request: request, path: "/api/event_logging/batch")
            }
            return await handleEventLoggingEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/api/providers"):
            let providers = ProviderRegistry.allProviders().map { ["id": $0.id, "displayName": $0.displayName, "description": $0.description] }
            return jsonResponse(providers, headers: corsHeaders)

        case ("GET", "/api/dashboard"):
            httpLog.debug("→ GET /api/dashboard")
            let ids = queryItems["ids"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let snapshot = await engine.fetchAll(ids: ids)
            return jsonResponse(encodable: snapshot, headers: corsHeaders)

        case ("GET", _) where path.hasPrefix("/api/provider/"):
            let providerId = String(path.dropFirst("/api/provider/".count))
            httpLog.debug("→ GET /api/provider/\(providerId)")
            guard let result = await engine.fetchSingle(id: providerId) else {
                return jsonResponse(["error": "Provider '\(providerId)' not found"], status: 404, headers: corsHeaders)
            }
            return jsonResponse(encodable: result, headers: corsHeaders)

        default:
            return jsonResponse(["error": "Not found"], status: 404, headers: corsHeaders)
        }
    }

    // MARK: - Error Helpers

    func claudeErrorResponse(type: String, message: String, status: Int, headers: [String: String]) -> HTTPResponse {
        let errorJSON = """
        {"type":"error","error":{"type":"\(type)","message":"\(message)"}}
        """
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(errorJSON.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: errorJSON)
    }

    func escapeJSON(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let json = String(data: data, encoding: .utf8),
              json.count > 2 else {
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        // Strip outer [ and ] to get the quoted string
        let start = json.index(after: json.startIndex)
        let end = json.index(before: json.endIndex)
        return String(json[start..<end])
    }

    // MARK: - HTTP Helpers

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var bodyString: String {
            String(data: body, encoding: .utf8) ?? ""
        }
    }

    struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    // MARK: - Streaming Response

    actor StreamingResponse {
        let connection: NWConnection
        private var headersSent = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func sendHeaders(status: Int, headers: [String: String]) async {
            guard !headersSent else { return }
            headersSent = true

            let statusText = httpStatusText(status)
            var headerLines = "HTTP/1.1 \(status) \(statusText)\r\n"
            for (key, value) in headers {
                headerLines += "\(key): \(value)\r\n"
            }
            headerLines += "\r\n"

            guard let data = headerLines.data(using: .utf8) else { return }
            await sendData(data)
        }

        func sendSSEEvent(event: String?, data: String) async {
            var message = ""
            if let event {
                message += "event: \(event)\n"
            }
            message += "data: \(data)\n\n"

            guard let eventData = message.data(using: .utf8) else { return }
            await sendData(eventData)
        }

        func sendChunk(_ text: String) async {
            guard let data = text.data(using: .utf8) else { return }
            await sendData(data)
        }

        nonisolated func close() {
            connection.cancel()
        }

        private func sendData(_ data: Data) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: data, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
        }

        private func httpStatusText(_ code: Int) -> String {
            [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][code] ?? "OK"
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            if index > 0, let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body
        let bodyLines = lines.dropFirst(bodyStartIndex)
        let bodyText = bodyLines.joined(separator: "\r\n")
        let bodyData = bodyText.data(using: .utf8) ?? Data()

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func parseQueryItems(_ path: String) -> [String: String] {
        guard let questionMark = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: questionMark)...])
        var result: [String: String] = [:]

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : ""
            result[key] = value
        }

        return result
    }

    func jsonResponse(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = "{}"
        }
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(body.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    func jsonResponse<T: Encodable>(encodable: T, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let body: String
        if let data = try? encoder.encode(encodable), let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = "{}"
        }
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(body.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    private func receiveData(_ connection: NWConnection) async -> Data? {
        // Support larger payloads (up to 10MB) with chunked reading
        let maxSize = 10 * 1024 * 1024 // 10MB
        var accumulated = Data()

        while accumulated.count < maxSize {
            guard let chunk = await receiveChunk(connection) else {
                break
            }
            accumulated.append(chunk)

            // Check if we have a complete HTTP request (headers + body)
            if let text = String(data: accumulated, encoding: .utf8),
               text.contains("\r\n\r\n") {
                // Check Content-Length to see if we have the full body
                if let contentLength = extractContentLength(from: text) {
                    guard let headerEnd = text.range(of: "\r\n\r\n") else {
                        continue
                    }
                    let headerEndOffset = text.distance(from: text.startIndex, to: headerEnd.upperBound)
                    let bodySize = accumulated.count - headerEndOffset
                    if bodySize >= contentLength {
                        break
                    }
                } else {
                    // No Content-Length, assume complete
                    break
                }
            }
        }

        return accumulated.isEmpty ? nil : accumulated
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: data)
            }
        }
    }

    private func extractContentLength(from text: String) -> Int? {
        let lines = text.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    func sendResponse(_ connection: NWConnection, response: HTTPResponse) async {
        let statusText = httpStatusText(response.status)
        var headerLines = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        for (key, value) in response.headers {
            headerLines += "\(key): \(value)\r\n"
        }
        headerLines += "\r\n"
        let full = (headerLines + response.body).data(using: .utf8) ?? Data()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: full, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func httpStatusText(_ code: Int) -> String {
        [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][code] ?? "OK"
    }
}

// MARK: - CLI Argument Parsing

func parseArgs() -> [String: String] {
    var result: [String: String] = [:]
    let args = CommandLine.arguments.dropFirst()
    var i = args.startIndex
    while i < args.endIndex {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            let nextIdx = args.index(after: i)
            if nextIdx < args.endIndex && !args[nextIdx].hasPrefix("--") {
                result[key] = args[nextIdx]
                i = args.index(after: nextIdx)
                continue
            }
        }
        i = args.index(after: i)
    }
    return result
}
