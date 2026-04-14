import Foundation
import QuotaBackend

extension ProxyViewModel {

    func restoreActivatedNode() {
        activatedConfigId = UserDefaults.standard.string(forKey: DefaultsKey.proxyActivatedConfigId)

        if activatedConfigId == nil {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            if migrated { saveConfigurations() }
        }

        guard let id = activatedConfigId else {
            settingsManager.clearEnv()
            clearPricingOverrides()
            return
        }

        guard let config = configurations.first(where: { $0.id == id }) else {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            activatedConfigId = nil
            if migrated { saveConfigurations() }
            saveActivatedId()
            settingsManager.clearEnv()
            clearPricingOverrides()
            return
        }

        print("⟳ Restoring node: \(config.name) (type=\(config.nodeType.rawValue))")

        if config.needsProxyProcess {
            startProxy(config)
        }
        settingsManager.writeEnv(envConfig(for: config))
        writePricingOverrides(config)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if let proc = self.runningProcesses[id] {
                print("  Proxy process isRunning=\(proc.isRunning) pid=\(proc.processIdentifier)")
            } else {
                print("  ⚠ No process found for restored node \(config.name)")
            }
        }
    }

    // MARK: - Proxy Server Control

    func startProxy(_ config: ProxyConfiguration) {
        guard config.needsProxyProcess else { return }
        if runningProcesses[config.id]?.isRunning == true {
            print("  Proxy already running for \(config.name)")
            return
        }

        killStaleProcess(port: config.port)

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

        let quotaServerPath = findQuotaServerExecutable()

        guard let executablePath = quotaServerPath else {
            print("✗ QuotaServer executable not found")
            return
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
                if line.hasPrefix("PROXY_LOG:"),
                   let jsonStart = line.firstIndex(of: Character("{")) {
                    let jsonStr = String(line[jsonStart...])
                    self?.parseProxyLog(jsonStr, configId: configId)
                }
            }
        }

        do {
            try process.run()
            runningProcesses[config.id] = process
            print("✓ Proxy started: \(config.name) on \(config.displayURL) (pid=\(process.processIdentifier))")

            process.terminationHandler = { [weak self] proc in
                print("⚠ Proxy process exited: \(config.name) code=\(proc.terminationStatus)")
                DispatchQueue.main.async {
                    self?.runningProcesses.removeValue(forKey: config.id)
                }
            }
        } catch {
            print("✗ Failed to start proxy: \(error.localizedDescription)")
        }
    }

    func killStaleProcess(port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try? lsof.run()
        lsof.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for pidStr in output.components(separatedBy: .whitespacesAndNewlines) where !pidStr.isEmpty {
            if let pid = Int32(pidStr), pid != ProcessInfo.processInfo.processIdentifier {
                print("  Killing stale process on port \(port): pid=\(pid)")
                kill(pid, SIGTERM)
                usleep(200_000)
            }
        }
    }

    func stopProxy(_ config: ProxyConfiguration) {
        guard let process = runningProcesses[config.id] else { return }
        process.terminate()
        runningProcesses.removeValue(forKey: config.id)
        print("✓ Proxy stopped: \(config.name)")
    }

    // MARK: - Pricing Overrides

    var pricingOverridePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-pricing.json")
    }

    func writePricingOverrides(_ config: ProxyConfiguration) {
        let mapping = config.modelMapping
        var pricing: [String: [String: Double]] = [:]

        let models: [ProxyConfiguration.MappedModel] = [mapping.bigModel, mapping.middleModel, mapping.smallModel]
        for m in models where !m.name.isEmpty {
            pricing[m.name] = [
                "input_per_million": m.pricing.inputPerMillionUSD,
                "output_per_million": m.pricing.outputPerMillionUSD,
                "cache_per_million": m.pricing.cachePerMillionUSD,
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
            logPersistenceError("write proxy pricing overrides", error: error)
        }
    }

    func clearPricingOverrides() {
        do {
            try FileManager.default.removeItem(atPath: pricingOverridePath)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            logPersistenceError("clear proxy pricing overrides", error: error)
        }
    }

    func isProxyRunning(_ configId: String) -> Bool {
        return runningProcesses[configId]?.isRunning ?? false
    }

    // MARK: - Log Parsing

    func parseProxyLog(_ jsonStr: String, configId: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log" else { return }

        let upstreamModel = json["upstream_model"] as? String ?? "unknown"
        let tokensInput = json["input_tokens"] as? Int ?? 0
        let tokensOutput = json["output_tokens"] as? Int ?? 0
        let tokensCache = json["cache_tokens"] as? Int ?? 0

        let config = configurations.first { $0.id == configId }
        let pricing = config?.pricingForModel(upstreamModel)
        let estimatedCost = pricing?.costForTokens(input: tokensInput, output: tokensOutput, cache: tokensCache) ?? 0

        let log = ProxyRequestLog(
            configId: configId,
            method: "POST",
            path: "/v1/messages",
            claudeModel: json["claude_model"] as? String ?? "unknown",
            upstreamModel: upstreamModel,
            success: json["success"] as? Bool ?? false,
            responseTimeMs: Double(json["response_time_ms"] as? Int ?? 0),
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            tokensCache: tokensCache,
            estimatedCostUSD: estimatedCost,
            errorMessage: json["error"] as? String
        )

        DispatchQueue.main.async { [weak self] in
            self?.recordRequest(log)
        }
    }
}
