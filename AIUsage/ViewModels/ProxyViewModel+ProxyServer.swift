import Foundation
import QuotaBackend
import os.log

extension ProxyViewModel {

    func restoreActivatedNode() {
        Task {
            await restoreActivatedNodeAsync()
        }
    }

    private func restoreActivatedNodeAsync() async {
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
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime while restoring empty activation state: \(String(describing: error), privacy: .public)")
            }
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
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime for missing restored node: \(String(describing: error), privacy: .public)")
            }
            return
        }

        print("⟳ Restoring node: \(config.name) (type=\(config.nodeType.rawValue))")

        do {
            try await activateRuntime(for: config)
            try persistActivationSelection(config.id, touchLastUsedAt: false)
        } catch {
            proxyRuntimeLog.error("Failed to restore proxy node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            activatedConfigId = nil
            for index in configurations.indices {
                configurations[index].isEnabled = false
            }
            saveConfigurations()
            saveActivatedId()
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime after restore failure: \(String(describing: error), privacy: .public)")
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if let description = self.runtimeService.processDebugDescription(for: id) {
                print("  \(description)")
            } else {
                print("  ⚠ No process found for restored node \(config.name)")
            }
        }
    }

    func activateRuntime(for config: ProxyConfiguration) async throws {
        try await runtimeService.activateRuntime(
            for: config,
            envConfig: envConfig(for: config)
        )
    }

    func deactivateRuntime(for config: ProxyConfiguration) async throws {
        try await runtimeService.deactivateRuntime(
            for: config,
            envConfig: envConfig(for: config)
        )
    }

    func isProxyRunning(_ configId: String) -> Bool {
        runtimeService.isProxyRunning(configId)
    }
}

extension ProxyViewModel: ProxyRuntimeServiceDelegate {
    func proxyRuntimeService(_ service: ProxyRuntimeService, didReceiveProxyLog json: String, configId: String) {
        parseProxyLog(json, configId: configId)
    }
}

extension ProxyViewModel {
    func parseProxyLog(_ jsonStr: String, configId: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log" else {
            return
        }

        let upstreamModel = json["upstream_model"] as? String ?? "unknown"
        let tokensInput = json["input_tokens"] as? Int ?? 0
        let tokensOutput = json["output_tokens"] as? Int ?? 0
        let tokensCache = json["cache_tokens"] as? Int ?? 0

        let config = configurations.first { $0.id == configId }
        let pricing = config?.pricingForModel(upstreamModel)
        let estimatedCost = pricing?.costForTokens(
            input: tokensInput,
            output: tokensOutput,
            cache: tokensCache
        ) ?? 0

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
