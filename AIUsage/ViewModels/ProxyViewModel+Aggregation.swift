import Foundation
import QuotaBackend

extension ProxyViewModel {

    // MARK: - Aggregation for ProxyStatsView

    func invalidateLogCache() {
        _logCache.removeAll()
    }

    func allLogs(nodeFilter: String?, modelFilter: String?) -> [ProxyRequestLog] {
        let key = LogCacheKey(nodeFilter: nodeFilter, modelFilter: modelFilter)
        if let cached = _logCache[key] { return cached }

        var result: [ProxyRequestLog] = []
        for (configId, logs) in recentLogs {
            if let node = nodeFilter, node != configId { continue }
            for log in logs {
                if let model = modelFilter, log.upstreamModel != model { continue }
                result.append(log)
            }
        }
        let sorted = result.sorted { $0.timestamp < $1.timestamp }
        _logCache[key] = sorted
        return sorted
    }

    struct DailyAggregate: Identifiable {
        let id: String
        let date: Date
        let label: String
        var cost: Double
        var tokens: Int
        var requests: Int
    }

    func dailyAggregates(nodeFilter: String?, modelFilter: String?) -> [DailyAggregate] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        let cal = Calendar.current
        var map: [String: DailyAggregate] = [:]
        for log in logs {
            let key = DateFormat.string(from: log.timestamp, format: "yyyy-MM-dd")
            let dayStart = cal.startOfDay(for: log.timestamp)
            var agg = map[key] ?? DailyAggregate(id: key, date: dayStart, label: key, cost: 0, tokens: 0, requests: 0)
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            map[key] = agg
        }

        return map.values.sorted { $0.date < $1.date }
    }

    func hourlyAggregates(nodeFilter: String?, modelFilter: String?) -> [DailyAggregate] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        let cal = Calendar.current
        var map: [String: DailyAggregate] = [:]
        for log in logs {
            let key = DateFormat.string(from: log.timestamp, format: "yyyy-MM-dd HH")
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: log.timestamp)
            let hourStart = cal.date(from: comps) ?? log.timestamp
            var agg = map[key] ?? DailyAggregate(id: key, date: hourStart, label: key, cost: 0, tokens: 0, requests: 0)
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            map[key] = agg
        }

        return map.values.sorted { $0.date < $1.date }
    }

    struct ModelTimePoint: Identifiable {
        let id: String
        let date: Date
        let model: String
        var cost: Double
        var tokens: Int
    }

    func modelTimeSeries(nodeFilter: String?, granularity: String) -> [ModelTimePoint] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: nil)
        guard !logs.isEmpty else { return [] }

        let cal = Calendar.current
        let format = granularity == "hourly" ? "yyyy-MM-dd HH" : "yyyy-MM-dd"

        var map: [String: ModelTimePoint] = [:]
        var allModels = Set<String>()
        var minDate = logs[0].timestamp
        var maxDate = logs[0].timestamp

        for log in logs {
            let timeKey = DateFormat.string(from: log.timestamp, format: format)
            let key = "\(timeKey)|\(log.upstreamModel)"
            let dateStart: Date
            if granularity == "hourly" {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: log.timestamp)
                dateStart = cal.date(from: comps) ?? log.timestamp
            } else {
                dateStart = cal.startOfDay(for: log.timestamp)
            }
            allModels.insert(log.upstreamModel)
            if log.timestamp < minDate { minDate = log.timestamp }
            if log.timestamp > maxDate { maxDate = log.timestamp }

            var pt = map[key] ?? ModelTimePoint(id: key, date: dateStart, model: log.upstreamModel, cost: 0, tokens: 0)
            pt.cost += log.estimatedCostUSD
            pt.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            map[key] = pt
        }

        let step: Calendar.Component = granularity == "hourly" ? .hour : .day
        var cursor: Date
        let end: Date
        if granularity == "hourly" {
            cursor = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: minDate)) ?? minDate
            end = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: maxDate)) ?? maxDate
        } else {
            cursor = cal.startOfDay(for: minDate)
            end = cal.startOfDay(for: maxDate)
        }

        while cursor <= end {
            let timeKey = DateFormat.string(from: cursor, format: format)
            for model in allModels {
                let key = "\(timeKey)|\(model)"
                if map[key] == nil {
                    map[key] = ModelTimePoint(id: key, date: cursor, model: model, cost: 0, tokens: 0)
                }
            }
            guard let next = cal.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }

        return map.values.sorted { ($0.date, $0.model) < ($1.date, $1.model) }
    }

    struct ModelAggregate: Identifiable {
        let id: String
        let model: String
        var cost: Double
        var tokens: Int
        var requests: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        /// cache_read / (input + cache_read + cache_creation) — percentage of billable input surface served from cache.
        var cacheHitRate: Double {
            let denom = inputTokens + cacheReadTokens + cacheCreationTokens
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(denom) * 100
        }
    }

    func modelAggregates(nodeFilter: String?, modelFilter: String?, since: Date? = nil) -> [ModelAggregate] {
        var logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        if let since { logs = logs.filter { $0.timestamp >= since } }
        var map: [String: ModelAggregate] = [:]

        for log in logs {
            let key = log.upstreamModel
            var agg = map[key] ?? ModelAggregate(
                id: key, model: key, cost: 0, tokens: 0, requests: 0,
                inputTokens: 0, outputTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0
            )
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            agg.inputTokens += log.tokensInput
            agg.outputTokens += log.tokensOutput
            agg.cacheReadTokens += log.tokensCacheRead
            agg.cacheCreationTokens += log.tokensCacheCreation
            map[key] = agg
        }

        return map.values.sorted { $0.cost > $1.cost }
    }

    func allUpstreamModels(nodeFilter: String?) -> [String] {
        var models = Set<String>()
        for (configId, logs) in recentLogs {
            if let node = nodeFilter, node != configId { continue }
            for log in logs { models.insert(log.upstreamModel) }
        }
        return models.sorted()
    }

    struct OverallStats {
        var cost: Double
        var tokens: Int
        var requests: Int
        var successRate: Double
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        /// cache_read / (input + cache_read + cache_creation). 0 when no cache-eligible traffic yet.
        var cacheHitRate: Double {
            let denom = inputTokens + cacheReadTokens + cacheCreationTokens
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(denom) * 100
        }
    }

    func overallStats(nodeFilter: String?, modelFilter: String?) -> OverallStats {
        overallStats(nodeFilter: nodeFilter, modelFilter: modelFilter, since: nil)
    }

    func overallStats(nodeFilter: String?, modelFilter: String?, since: Date?) -> OverallStats {
        var logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        if let since { logs = logs.filter { $0.timestamp >= since } }

        var cost = 0.0, tokens = 0, input = 0, output = 0
        var cacheRead = 0, cacheCreate = 0, successCount = 0
        for log in logs {
            cost += log.estimatedCostUSD
            let logTokens = log.tokensInput + log.tokensOutput + log.tokensCache
            tokens += logTokens
            input += log.tokensInput
            output += log.tokensOutput
            cacheRead += log.tokensCacheRead
            cacheCreate += log.tokensCacheCreation
            if log.success { successCount += 1 }
        }
        let rate = logs.isEmpty ? 0.0 : Double(successCount) / Double(logs.count) * 100
        return OverallStats(
            cost: cost,
            tokens: tokens,
            requests: logs.count,
            successRate: rate,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate
        )
    }

    func dataDateRange(nodeFilter: String?, modelFilter: String?) -> (earliest: Date?, latest: Date?, days: Int) {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        guard let earliest = logs.first?.timestamp, let latest = logs.last?.timestamp else {
            return (nil, nil, 0)
        }
        let calendar = Calendar.current
        let earliestDay = calendar.startOfDay(for: earliest)
        let latestDay = calendar.startOfDay(for: latest)
        let days = max(1, (calendar.dateComponents([.day], from: earliestDay, to: latestDay).day ?? 0) + 1)
        return (earliest, latest, days)
    }
}
