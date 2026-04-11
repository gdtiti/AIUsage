import Foundation
import QuotaBackend

// MARK: - QuotaServer Entry Point
// Usage: swift run QuotaServer [--port 4318] [--host 0.0.0.0]

let args = parseArgs()
let host = args["host"] ?? "127.0.0.1"
let port = Int(args["port"] ?? "4318") ?? 4318

print("QuotaServer starting on \(host):\(port)")

let server = QuotaHTTPServer(host: host, port: port)
try await server.run()
