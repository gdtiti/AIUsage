import Foundation
import XCTest
@testable import QuotaBackend
import QuotaServerCore

final class QuotaHTTPServerProxyIntegrationTests: XCTestCase {

    func testHealthEndpointReportsReady() async throws {
        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(host: "127.0.0.1", port: proxyPort)
        try await server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertFalse((json["generatedAt"] as? String ?? "").isEmpty)
    }

    func testMessagesEndpointRejectsInvalidClientKey() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "chatcmpl-test",
                    "object": "chat.completion",
                    "created": 1,
                    "model": "gpt-4o-mini",
                    "choices": [
                        [
                            "index": 0,
                            "message": ["role": "assistant", "content": "should not be reached"],
                            "finish_reason": "stop",
                        ],
                    ],
                    "usage": [
                        "prompt_tokens": 1,
                        "completion_tokens": 1,
                        "total_tokens": 2,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "wrong-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)

        let decoded = try JSONDecoder().decode(ClaudeErrorResponse.self, from: data)
        XCTAssertEqual(decoded.error.type, "authentication_error")
        XCTAssertEqual(decoded.error.message, "Invalid API key")
        let recordedRequests = await upstream.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testCountTokensEndpointReturnsHeuristicEstimate() async throws {
        let upstreamPort = try findFreePort()
        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages/count_tokens")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("client-key", forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "system": "You are a helpful assistant.",
                "messages": [
                    ["role": "user", "content": "Please count these tokens."],
                ],
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let tokenCount = try JSONDecoder().decode(ClaudeTokenCountResponse.self, from: data)
        XCTAssertGreaterThan(tokenCount.inputTokens, 0)
    }

    func testOpenAIConvertProxyNonStreamingRoundTrip() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "chatcmpl-nonstream",
                    "object": "chat.completion",
                    "created": 1_710_000_000,
                    "model": "gpt-4o-mini",
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": "Hello from upstream",
                            ],
                            "finish_reason": "stop",
                        ],
                    ],
                    "usage": [
                        "prompt_tokens": 12,
                        "completion_tokens": 5,
                        "total_tokens": 17,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(firstTextBlock(in: decoded.content), "Hello from upstream")
        XCTAssertEqual(decoded.stopReason, "end_turn")
        XCTAssertEqual(decoded.usage.outputTokens, 5)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.method, "POST")
        XCTAssertEqual(upstreamRequest.path, "/v1/chat/completions")
        XCTAssertEqual(upstreamRequest.headers["authorization"], "Bearer upstream-key")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(upstreamBody["stream"] as? Bool, false)
    }

    func testOpenAIConvertProxyStreamingRoundTrip() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"id\":\"chatcmpl-stream\",\"object\":\"chat.completion.chunk\",\"created\":1710000001,\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n",
                    "data: {\"id\":\"chatcmpl-stream\",\"object\":\"chat.completion.chunk\",\"created\":1710000001,\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" world\"},\"finish_reason\":\"stop\"}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("event: message_start"))
        XCTAssertTrue(joined.contains("event: content_block_delta"))
        XCTAssertTrue(joined.contains("\"text\":\"Hello\""))
        XCTAssertTrue(joined.contains("\"text\":\" world\""))
        XCTAssertTrue(joined.contains("event: message_stop"))

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first).body) as? [String: Any]
        )
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-4o-mini")
    }

    func testAnthropicPassthroughNonStreamingForwarding() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "msg_passthrough",
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "text",
                            "text": "passthrough ok",
                        ],
                    ],
                    "model": "claude-3-5-sonnet-20241022",
                    "stop_reason": "end_turn",
                    "stop_sequence": NSNull(),
                    "usage": [
                        "input_tokens": 8,
                        "output_tokens": 4,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: ClaudeProxyConfiguration(
                enabled: true,
                bindPort: proxyPort,
                mode: .anthropicPassthrough,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
                upstreamAPIKey: "upstream-anthropic-key",
                expectedClientKey: "client-key"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(firstTextBlock(in: decoded.content), "passthrough ok")

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/messages")
        XCTAssertEqual(upstreamRequest.headers["x-api-key"], "upstream-anthropic-key")
    }

    private func makeOpenAIProxyConfiguration(upstreamPort: Int) -> ClaudeProxyConfiguration {
        ClaudeProxyConfiguration(
            enabled: true,
            bindPort: 4318,
            mode: .openaiConvert,
            upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
            upstreamAPIKey: "upstream-key",
            expectedClientKey: "client-key",
            bigModel: "gpt-4.1",
            middleModel: "gpt-4o-mini",
            smallModel: "gpt-4.1-nano",
            maxOutputTokens: 512
        )
    }

    private func makeClaudeMessagesRequest(proxyPort: Int, clientKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 10
        return request
    }

    private func makeClaudeMessagesBody(stream: Bool) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    [
                        "role": "user",
                        "content": "Say hello",
                    ],
                ],
                "max_tokens": 64,
                "stream": stream,
            ]
        )
    }

    private func firstTextBlock(in blocks: [ClaudeContentBlock]) -> String? {
        for block in blocks {
            if case .text(let textBlock) = block {
                return textBlock.text
            }
        }
        return nil
    }
}
