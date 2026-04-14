import Foundation

// MARK: - CLI executable resolution (PATH + common install locations)

/// Resolves a CLI tool by name: consults `which` first, then known install paths (Homebrew, system, user bins).
enum CLIExecutableResolution {
    /// Try `which` first (respects PATH, works with nix/asdf/homebrew); then fall back to known paths.
    static func resolvedExecutable(named name: String) -> String? {
        if let path = runWhich(name) { return path }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/bin/\(name)",
            "\(home)/.cargo/bin/\(name)"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    private static func runWhich(_ name: String) -> String? {
        let whichPath = "/usr/bin/which"
        guard FileManager.default.isExecutableFile(atPath: whichPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whichPath)
        process.arguments = [name]
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else { return nil }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
