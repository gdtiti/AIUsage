import Foundation

// MARK: - Passthrough Interceptor Protocol
// Defines a pluggable hook for modifying Anthropic passthrough requests
// before they are forwarded to the upstream server. Implementations can
// rewrite headers and body without changing the core proxy logic.

public protocol PassthroughInterceptor: Sendable {
    /// Intercept and optionally modify a passthrough request.
    /// - Parameters:
    ///   - path: The request path (e.g. "/v1/messages").
    ///   - headers: Mutable request headers; modify in place.
    ///   - body: Mutable request body; modify in place.
    /// - Returns: `true` if the request was modified, `false` if passed through unchanged.
    func intercept(
        path: String,
        headers: inout [String: String],
        body: inout Data
    ) -> Bool
}
