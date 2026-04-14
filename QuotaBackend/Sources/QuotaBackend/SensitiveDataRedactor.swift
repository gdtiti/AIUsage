import Foundation

public enum SensitiveDataRedactor {
    private static let replacementPath = "<redacted-path>"

    // MARK: - Internal Helpers

    /// Matches only the empty string; used as a safe fallback when a built-in pattern fails to compile.
    private static let noMatchUnlessEmptyRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "\\A\\z", options: [])
        } catch {
            preconditionFailure("Built-in fallback regex must compile: \(error)")
        }
    }()

    private static func compiledRegex(pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            assertionFailure("Invalid regex pattern: \(error)")
            return noMatchUnlessEmptyRegex
        }
    }

    private static let pathPatterns: [NSRegularExpression] = [
        compiledRegex(pattern: #"(^|\s)(file:///[^[:space:])'",;]+)"#),
        compiledRegex(pattern: #"(^|\s)(~\/.*?\.(?:json|ya?ml|sqlite|db|txt|log))(?=$|\s|[),.:;])"#),
        compiledRegex(pattern: #"(^|\s)(\/.*?\.(?:json|ya?ml|sqlite|db|txt|log))(?=$|\s|[),.:;])"#),
        compiledRegex(pattern: #"(^|\s)(~\/.*?\/Cookies(?:[-.\w]*)?)(?=$|\s|[),.:;])"#),
        compiledRegex(pattern: #"(^|\s)(\/.*?\/Cookies(?:[-.\w]*)?)(?=$|\s|[),.:;])"#)
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
