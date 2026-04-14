import Foundation

func aiusageDefaultCLIPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let segments = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(home)/.local/bin",
        "\(home)/bin",
        "\(home)/.cargo/bin"
    ]

    var seen = Set<String>()
    return segments.filter { seen.insert($0).inserted }.joined(separator: ":")
}

func aiusageResolvedExecutable(named executable: String) -> String? {
    if let path = aiusageRunWhich(executable) { return path }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/opt/homebrew/bin/\(executable)",
        "/usr/local/bin/\(executable)",
        "/usr/bin/\(executable)",
        "/bin/\(executable)",
        "\(home)/.local/bin/\(executable)",
        "\(home)/bin/\(executable)",
        "\(home)/.cargo/bin/\(executable)"
    ]

    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    return nil
}

private func aiusageRunWhich(_ name: String) -> String? {
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
