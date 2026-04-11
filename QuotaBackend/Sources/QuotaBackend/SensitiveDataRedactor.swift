import Foundation

public enum SensitiveDataRedactor {
    private static let replacementPath = "<redacted-path>"

    private static let pathPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(^|\s)(file:///[^[:space:])'",;]+)"#),
        try! NSRegularExpression(pattern: #"(^|\s)(~\/.*?\.(?:json|ya?ml|sqlite|db|txt|log))(?=$|\s|[),.:;])"#),
        try! NSRegularExpression(pattern: #"(^|\s)(\/.*?\.(?:json|ya?ml|sqlite|db|txt|log))(?=$|\s|[),.:;])"#),
        try! NSRegularExpression(pattern: #"(^|\s)(~\/.*?\/Cookies(?:[-.\w]*)?)(?=$|\s|[),.:;])"#),
        try! NSRegularExpression(pattern: #"(^|\s)(\/.*?\/Cookies(?:[-.\w]*)?)(?=$|\s|[),.:;])"#)
    ]

    public static func redactPaths(in text: String) -> String {
        guard !text.isEmpty else { return text }

        var sanitized = text
        for pattern in pathPatterns {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = pattern.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "$1\(replacementPath)"
            )
        }
        return sanitized
    }

    public static func redactedMessage(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.redactedMessage
        }
        return redactPaths(in: error.localizedDescription)
    }

    public static func redactedDescription(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.redactedDescription
        }
        return redactPaths(in: error.localizedDescription)
    }
}

public extension ProviderError {
    var redactedMessage: String {
        SensitiveDataRedactor.redactPaths(in: message)
    }

    var redactedDescription: String {
        "[\(code)] \(redactedMessage)"
    }
}
