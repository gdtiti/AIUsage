import Foundation

// MARK: - Claude Settings Manager

class ClaudeSettingsManager {
    static let shared = ClaudeSettingsManager()

    private var settingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".claude/settings.json")
    }

    func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private let managedEnvKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    struct EnvConfig {
        var baseURL: String?
        var authToken: String?
        var defaultModel: String?
        var opusModel: String?
        var sonnetModel: String?
        var haikuModel: String?
    }

    func writeEnv(_ config: EnvConfig) {
        var settings = readSettings()
        var env = settings["env"] as? [String: Any] ?? [:]

        let pairs: [(String, String?)] = [
            ("ANTHROPIC_BASE_URL", config.baseURL),
            ("ANTHROPIC_AUTH_TOKEN", config.authToken),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", config.opusModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", config.sonnetModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", config.haikuModel),
        ]
        for (key, value) in pairs {
            if let value = value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }

        settings["env"] = env

        if let model = config.defaultModel, !model.isEmpty {
            settings["model"] = model
        } else {
            settings.removeValue(forKey: "model")
        }

        writeSettings(settings)
    }

    func clearEnv() {
        var settings = readSettings()
        var env = settings["env"] as? [String: Any] ?? [:]
        for key in managedEnvKeys {
            env.removeValue(forKey: key)
        }
        settings["env"] = env
        settings.removeValue(forKey: "model")
        writeSettings(settings)
    }

    private func writeSettings(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }

        let dir = (settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: settingsPath))
    }
}
