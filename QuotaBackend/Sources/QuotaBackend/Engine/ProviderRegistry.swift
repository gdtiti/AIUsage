import Foundation

// MARK: - Provider Registry
// Central list of all providers. Add new providers here.

public enum ProviderRegistry {

    public static func allProviders() -> [any ProviderFetcher] {
        [
            AmpProvider(),
            AntigravityProvider(),
            ClaudeProvider(),
            CodexProvider(),
            CopilotProvider(),
            CursorProvider(),
            DroidProvider(),
            GeminiProvider(),
            KiroProvider(),
            WarpProvider()
        ]
    }

    public static func providers(for ids: [String]) -> [any ProviderFetcher] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        return allProviders().filter { wanted.contains($0.id) }
    }

    public static func provider(for id: String) -> (any ProviderFetcher)? {
        allProviders().first { $0.id == id }
    }
}
