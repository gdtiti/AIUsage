import Foundation
import QuotaBackend
import os.log

private actor ProxyProcessInspector {
    static let shared = ProxyProcessInspector()

    func killStaleProcesses(port: Int, currentProcessIdentifier: Int32) throws {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        lsof.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for pidStr in output.components(separatedBy: .whitespacesAndNewlines) where !pidStr.isEmpty {
            guard let pid = Int32(pidStr), pid != currentProcessIdentifier else { continue }
            print("  Killing stale process on port \(port): pid=\(pid)")
            kill(pid, SIGTERM)
            usleep(200_000)
        }
    }
}

@MainActor
protocol ProxyRuntimeServiceDelegate: AnyObject {
    func proxyRuntimeService(_ service: ProxyRuntimeService, didReceiveProxyLog json: String, configId: String)
}

@MainActor
final class ProxyRuntimeService {
    private static let sourceFileDir: String = {
        let filePath = #filePath
        return (filePath as NSString).deletingLastPathComponent
    }()

    weak var delegate: ProxyRuntimeServiceDelegate?

    private let settingsManager: ClaudeSettingsManager
    private var runningProcesses: [String: Process] = [:]

    init(settingsManager: ClaudeSettingsManager? = nil) {
        self.settingsManager = settingsManager ?? ClaudeSettingsManager.shared
    }

    func activateRuntime(
        for config: ProxyConfiguration,
        envConfig: ClaudeSettingsManager.EnvConfig
    ) async throws {
        if config.needsProxyProcess {
            try await startProxy(config)
        }

        do {
            try settingsManager.writeEnv(envConfig)
            try writePricingOverrides(config)
        } catch {
            if config.needsProxyProcess {
                stopProxy(config)
            }
            do {
                try settingsManager.clearEnv()
            } catch {
                proxyRuntimeLog.error("Failed to clear Claude runtime env while rolling back node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            do {
                try clearPricingOverrides()
            } catch {
                proxyRuntimeLog.error("Failed to clear pricing overrides while rolling back node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    func deactivateRuntime(
        for config: ProxyConfiguration,
        envConfig: ClaudeSettingsManager.EnvConfig
    ) async throws {
        if config.needsProxyProcess {
            stopProxy(config)
        }

        do {
            try settingsManager.clearEnv()
            try clearPricingOverrides()
        } catch {
            do {
                try await activateRuntime(for: config, envConfig: envConfig)
            } catch {
                proxyRuntimeLog.error("Failed to restore runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    func clearRuntime() throws {
        try settingsManager.clearEnv()
        try clearPricingOverrides()
    }

    func isProxyRunning(_ configId: String) -> Bool {
        guard let process = runningProcesses[configId] else { return false }
        if !process.isRunning {
            runningProcesses.removeValue(forKey: configId)
            return false
        }
        return true
    }

    func processDebugDescription(for configId: String) -> String? {
        guard let process = runningProcesses[configId] else { return nil }
        return "Proxy process isRunning=\(process.isRunning) pid=\(process.processIdentifier)"
    }

    private func startProxy(_ config: ProxyConfiguration) async throws {
        guard config.needsProxyProcess else { return }
        if runningProcesses[config.id]?.isRunning == true {
            print("  Proxy already running for \(config.name)")
            return
        }

        do {
            try await ProxyProcessInspector.shared.killStaleProcesses(
                port: config.port,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            proxyRuntimeLog.error("Failed to inspect stale proxy process on port \(config.port, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        var environment = ProcessInfo.processInfo.environment

        if config.nodeType == .anthropicDirect && config.usePassthroughProxy {
            environment["PROXY_MODE"] = "passthrough"
            environment["ANTHROPIC_UPSTREAM_URL"] = config.anthropicBaseURL
            environment["ANTHROPIC_UPSTREAM_KEY"] = config.anthropicAPIKey
            if !config.expectedClientKey.isEmpty {
                environment["ANTHROPIC_API_KEY"] = config.expectedClientKey
            }
        } else {
            environment["OPENAI_API_KEY"] = config.upstreamAPIKey
            environment["OPENAI_BASE_URL"] = config.upstreamBaseURL
            environment["BIG_MODEL"] = config.modelMapping.bigModel.name
            environment["MIDDLE_MODEL"] = config.modelMapping.middleModel.name
            environment["SMALL_MODEL"] = config.modelMapping.smallModel.name

            if config.maxOutputTokens > 0 {
                environment["MAX_OUTPUT_TOKENS"] = "\(config.maxOutputTokens)"
            }

            if !config.expectedClientKey.isEmpty {
                environment["ANTHROPIC_API_KEY"] = config.expectedClientKey
            }
        }

        guard let executablePath = findQuotaServerExecutable() else {
            print("✗ QuotaServer executable not found")
            throw ProxyRuntimeError.quotaServerNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--host", config.bindAddress,
            "--port", "\(config.port)"
        ]
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let configId = config.id
        let configName = config.name
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[Proxy \(configName)] \(trimmed)")

            for line in trimmed.components(separatedBy: .newlines) {
                guard line.hasPrefix("PROXY_LOG:"),
                      let jsonStart = line.firstIndex(of: Character("{")) else {
                    continue
                }

                let jsonStr = String(line[jsonStart...])
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.proxyRuntimeService(self, didReceiveProxyLog: jsonStr, configId: configId)
                }
            }
        }

        do {
            try process.run()
            try await Task.sleep(nanoseconds: 200_000_000)
            if !process.isRunning {
                throw ProxyRuntimeError.proxyStartFailed("process exited with code \(process.terminationStatus)")
            }
            runningProcesses[config.id] = process
            print("✓ Proxy started: \(config.name) on \(config.displayURL) (pid=\(process.processIdentifier))")

            process.terminationHandler = { [weak self] proc in
                print("⚠ Proxy process exited: \(config.name) code=\(proc.terminationStatus)")
                Task { @MainActor [weak self] in
                    self?.runningProcesses.removeValue(forKey: config.id)
                }
            }
        } catch {
            print("✗ Failed to start proxy: \(error.localizedDescription)")
            throw error is ProxyRuntimeError
                ? error
                : ProxyRuntimeError.proxyStartFailed(error.localizedDescription)
        }
    }

    private func stopProxy(_ config: ProxyConfiguration) {
        guard let process = runningProcesses[config.id] else { return }
        process.terminate()
        runningProcesses.removeValue(forKey: config.id)
        print("✓ Proxy stopped: \(config.name)")
    }

    private var pricingOverridePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-pricing.json")
    }

    private func writePricingOverrides(_ config: ProxyConfiguration) throws {
        let mapping = config.modelMapping
        var pricing: [String: [String: Double]] = [:]

        let models: [ProxyConfiguration.MappedModel] = [mapping.bigModel, mapping.middleModel, mapping.smallModel]
        for model in models where !model.name.isEmpty {
            pricing[model.name] = [
                "input_per_million": model.pricing.inputPerMillionUSD,
                "output_per_million": model.pricing.outputPerMillionUSD,
                "cache_per_million": model.pricing.cachePerMillionUSD,
            ]
        }

        let result: [String: Any] = ["pricing": pricing]

        do {
            let url = URL(fileURLWithPath: pricingOverridePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            proxyPersistenceLog.error("Failed to write proxy pricing overrides: \(String(describing: error), privacy: .public)")
            throw ProxyRuntimeError.pricingOverridesWriteFailed
        }
    }

    private func clearPricingOverrides() throws {
        do {
            try FileManager.default.removeItem(atPath: pricingOverridePath)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            proxyPersistenceLog.error("Failed to clear proxy pricing overrides: \(String(describing: error), privacy: .public)")
            throw ProxyRuntimeError.pricingOverridesClearFailed
        }
    }

    private func findQuotaServerExecutable() -> String? {
        let fileManager = FileManager.default

        let sourceProjectRoot = (Self.sourceFileDir as NSString).deletingLastPathComponent
        let projectRootFromSource = (sourceProjectRoot as NSString).deletingLastPathComponent
        let bundlePath = Bundle.main.bundlePath

        let candidateRoots = [
            projectRootFromSource,
            bundlePath,
        ]

        let relativePaths = [
            "QuotaBackend/.build/debug/QuotaServer",
            "QuotaBackend/.build/release/QuotaServer",
        ]

        for root in candidateRoots {
            for relPath in relativePaths {
                let fullPath = (root as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    print("Found QuotaServer at: \(fullPath)")
                    return fullPath
                }
            }
        }

        var searchDir = projectRootFromSource
        for _ in 0..<5 {
            for relPath in relativePaths {
                let fullPath = (searchDir as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    print("Found QuotaServer at: \(fullPath)")
                    return fullPath
                }
            }
            searchDir = (searchDir as NSString).deletingLastPathComponent
        }

        print("✗ QuotaServer executable not found in expected build outputs")
        print("  #filePath resolved to: \(Self.sourceFileDir)")
        print("  Bundle.main.bundlePath: \(bundlePath)")
        return nil
    }
}
