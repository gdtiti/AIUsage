import Foundation
import QuotaBackend

extension ProxyViewModel {

    // MARK: - Statistics Management

    func loadStatistics() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyStatistics) else {
            return
        }

        do {
            statistics = try JSONDecoder().decode([String: ProxyStatistics].self, from: data)
        } catch {
            logPersistenceError("load proxy statistics", error: error)
        }
    }

    @discardableResult
    func saveStatistics() -> Bool {
        do {
            let data = try JSONEncoder().encode(statistics)
            UserDefaults.standard.set(data, forKey: DefaultsKey.proxyStatistics)
            return true
        } catch {
            logPersistenceError("save proxy statistics", error: error)
            return false
        }
    }

    func recordRequest(_ log: ProxyRequestLog) {
        var stats = statistics[log.configId] ?? .empty
        stats.totalRequests += 1
        if log.success {
            stats.successfulRequests += 1
        } else {
            stats.failedRequests += 1
        }
        stats.totalTokensInput += log.tokensInput
        stats.totalTokensOutput += log.tokensOutput
        stats.totalTokensCache += log.tokensCache
        stats.estimatedCostUSD += log.estimatedCostUSD
        stats.lastRequestAt = log.timestamp

        let totalTime = stats.averageResponseTime * Double(stats.totalRequests - 1) + log.responseTimeMs
        stats.averageResponseTime = totalTime / Double(stats.totalRequests)

        stats.requestsByModel[log.upstreamModel, default: 0] += 1

        statistics[log.configId] = stats

        var logs = recentLogs[log.configId] ?? []
        logs.insert(log, at: 0)
        recentLogs[log.configId] = logs

        saveStatistics()
        saveLogs()
    }

    /// Fill in costs for logs that have estimatedCostUSD == 0 (pricing was missing at creation time).
    /// Logs with existing non-zero costs are preserved as-is.
    func recalculateCosts(for configId: String) {
        guard let config = configurations.first(where: { $0.id == configId }),
              let logs = recentLogs[configId] else { return }

        var changed = false
        var updatedLogs: [ProxyRequestLog] = []

        for log in logs {
            if log.estimatedCostUSD == 0, log.tokensInput + log.tokensOutput + log.tokensCache > 0 {
                let pricing = config.pricingForModel(log.upstreamModel)
                let cost = pricing?.costForTokens(input: log.tokensInput, output: log.tokensOutput, cache: log.tokensCache) ?? 0
                if cost > 0 {
                    changed = true
                    updatedLogs.append(ProxyRequestLog(
                        id: log.id, configId: log.configId, timestamp: log.timestamp,
                        method: log.method, path: log.path,
                        claudeModel: log.claudeModel, upstreamModel: log.upstreamModel,
                        success: log.success, responseTimeMs: log.responseTimeMs,
                        tokensInput: log.tokensInput, tokensOutput: log.tokensOutput,
                        tokensCache: log.tokensCache, estimatedCostUSD: cost,
                        errorMessage: log.errorMessage
                    ))
                    continue
                }
            }
            updatedLogs.append(log)
        }

        if changed {
            recentLogs[configId] = updatedLogs
            let totalCost = updatedLogs.reduce(0.0) { $0 + $1.estimatedCostUSD }
            if var stats = statistics[configId] {
                stats.estimatedCostUSD = totalCost
                statistics[configId] = stats
            }
            saveStatistics()
            saveLogs()
        }
    }

    // MARK: - Logs Management

    func loadLogs() {
        let url = URL(fileURLWithPath: logsFilePath)

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                recentLogs = try JSONDecoder().decode([String: [ProxyRequestLog]].self, from: data)
            } catch {
                logPersistenceError("load proxy logs", error: error)
            }
        } else if let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyLogs) {
            do {
                recentLogs = try JSONDecoder().decode([String: [ProxyRequestLog]].self, from: data)
                UserDefaults.standard.removeObject(forKey: DefaultsKey.proxyLogs)
                saveLogs()
            } catch {
                logPersistenceError("migrate legacy proxy logs", error: error)
            }
        }
        pruneOldLogs()
    }

    @discardableResult
    func saveLogs() -> Bool {
        let url = URL(fileURLWithPath: logsFilePath)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(recentLogs)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            logPersistenceError("save proxy logs", error: error)
            return false
        }
    }

    func pruneOldLogs() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date()) ?? .distantPast
        var pruned = false
        for (configId, logs) in recentLogs {
            let filtered = logs.filter { $0.timestamp > cutoff }
            if filtered.count != logs.count {
                recentLogs[configId] = filtered
                pruned = true
            }
        }
        if pruned { saveLogs() }
    }

    func clearLogs(for configId: String) {
        recentLogs[configId] = []
        saveLogs()
    }

    func clearAllLogs() {
        recentLogs.removeAll()
        saveLogs()
    }
}
