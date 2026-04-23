import Foundation
import os.log

// MARK: - AnyRouter Thinking Interceptor
// Fixes Claude Code SubAgent requests that send missing, null, or
// {type:"disabled"} thinking fields — which cause 500 errors on
// AnyRouter and similar third-party Anthropic-compatible gateways.
//
// Rewrite strategy (mirrors Claude Code's internal per-model normalization):
//   - claude-3-*                   -> remove thinking field
//   - opus-4-[67] / sonnet-4-6    -> { type: "adaptive" }
//   - others (haiku-4-*, etc.)    -> { type: "enabled", budget_tokens } +
//                                    temperature=1, remove top_p/top_k
//
// When thinking is enabled, also injects the interleaved-thinking beta header
// required for tool_use + thinking coexistence.

private let interceptorLog = Logger(subsystem: "com.aiusage.quotaserver", category: "AnyRouterInterceptor")

private let interleavedThinkingBeta = "interleaved-thinking-2025-05-14"

public struct AnyRouterInterceptor: PassthroughInterceptor {

    public init() {}

    public func intercept(
        path: String,
        headers: inout [String: String],
        body: inout Data
    ) -> Bool {
        guard path == "/v1/messages" else { return false }
        guard !body.isEmpty else { return false }

        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }

        let result = rewriteThinking(&json)
        guard let result else { return false }

        if result.enabledThinking {
            normalizeForThinking(&json)
            ensureInterleavedBeta(&headers)
        }

        guard let newBody = try? JSONSerialization.data(withJSONObject: json) else {
            return false
        }
        body = newBody

        interceptorLog.info("rewrite: \(result.decision, privacy: .public)")
        return true
    }

    // MARK: - Thinking Rewrite

    private struct RewriteResult {
        let decision: String
        let enabledThinking: Bool
    }

    private func rewriteThinking(_ json: inout [String: Any]) -> RewriteResult? {
        let thinkingExists = json.keys.contains("thinking")
        let thinkingValue = json["thinking"]

        let isAbsent = !thinkingExists
            || thinkingValue is NSNull
            || thinkingValue == nil

        let isDisabled: Bool = {
            guard let dict = thinkingValue as? [String: Any] else { return false }
            return (dict["type"] as? String) == "disabled"
        }()

        guard isAbsent || isDisabled else { return nil }

        let origState = isAbsent ? "absent" : "disabled"
        let model = (json["model"] as? String ?? "").lowercased()

        if model.contains("claude-3-") {
            guard thinkingExists else { return nil }
            json.removeValue(forKey: "thinking")
            return RewriteResult(
                decision: "deleted(legacy, from:\(origState))",
                enabledThinking: false
            )
        }

        if model.range(of: #"opus-4-[67]|sonnet-4-6"#, options: .regularExpression) != nil {
            json["thinking"] = ["type": "adaptive"]
            return RewriteResult(
                decision: "adaptive(from:\(origState))",
                enabledThinking: true
            )
        }

        let callerMax = (json["max_tokens"] as? Int)
            ?? (json["max_tokens"] as? Double).map { Int($0) }
        var maxTokens = (callerMax != nil && callerMax! > 0) ? callerMax! : 32_000
        if maxTokens <= 1024 { maxTokens = 2048 }
        json["max_tokens"] = maxTokens
        let budget = min(31_999, maxTokens - 1)
        json["thinking"] = ["type": "enabled", "budget_tokens": budget]

        return RewriteResult(
            decision: "enabled(budget=\(budget), max=\(maxTokens), from:\(origState))",
            enabledThinking: true
        )
    }

    /// Anthropic API requires temperature=1 and forbids top_p/top_k when thinking is active.
    private func normalizeForThinking(_ json: inout [String: Any]) {
        json["temperature"] = 1
        json.removeValue(forKey: "top_p")
        json.removeValue(forKey: "top_k")
    }

    // MARK: - Beta Header Injection

    private func ensureInterleavedBeta(_ headers: inout [String: String]) {
        let key = "anthropic-beta"
        let existing = headers[key] ?? ""
        var betas = existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !betas.contains(interleavedThinkingBeta) else { return }
        betas.append(interleavedThinkingBeta)
        headers[key] = betas.joined(separator: ",")
    }
}
