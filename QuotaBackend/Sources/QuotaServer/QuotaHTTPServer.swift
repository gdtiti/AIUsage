import Foundation
import Network
import QuotaBackend

// MARK: - Lightweight HTTP Server
// Uses Network.framework (no external dependencies) to serve the same JSON API
// as the original Node.js backend.

public final class QuotaHTTPServer: @unchecked Sendable {
    let host: String
    let port: Int
    let engine = ProviderEngine()

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public func run() async throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }
        listener.start(queue: .global())
        print("QuotaServer listening on \(host):\(port)")
        print("Endpoints:")
        print("  GET /api/dashboard")
        print("  GET /api/provider/:id")
        print("  GET /api/providers")
        print("  GET /api/health")
        print("  GET /health")

        // Keep alive
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("Server failed: \(error)")
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
            let generatedAt = ISO8601DateFormatter().string(from: Date())
            return jsonResponse(
                [
                    "ok": true,
                    "generatedAt": generatedAt,
                    "status": "ok",
                    "time": generatedAt
                ],
                headers: corsHeaders
            )

        case ("GET", "/api/providers"):
            let providers = ProviderRegistry.allProviders().map { ["id": $0.id, "displayName": $0.displayName, "description": $0.description] }
            return jsonResponse(providers, headers: corsHeaders)

        case ("GET", "/api/dashboard"):
            print("→ GET /api/dashboard")
            let ids = queryItems["ids"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let snapshot = await engine.fetchAll(ids: ids)
            return jsonResponse(encodable: snapshot, headers: corsHeaders)

        case ("GET", _) where path.hasPrefix("/api/provider/"):
            let providerId = String(path.dropFirst("/api/provider/".count))
            print("→ GET /api/provider/\(providerId)")
            guard let result = await engine.fetchSingle(id: providerId) else {
                return jsonResponse(["error": "Provider '\(providerId)' not found"], status: 404, headers: corsHeaders)
            }
            return jsonResponse(encodable: result, headers: corsHeaders)

        default:
            return jsonResponse(["error": "Not found"], status: 404, headers: corsHeaders)
        }
    }

    // MARK: - HTTP Helpers

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: String
    }

    private struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        let separator = "\r\n\r\n"
        let body = text.components(separatedBy: separator).dropFirst().joined(separator: separator)
        return HTTPRequest(method: method, path: path, body: body)
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

    private func jsonResponse(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
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

    private func jsonResponse<T: Encodable>(encodable: T, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
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
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: data)
            }
        }
    }

    private func sendResponse(_ connection: NWConnection, response: HTTPResponse) async {
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
