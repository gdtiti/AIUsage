import SwiftUI
import Combine
import Foundation
import os.log
import QuotaBackend

// MARK: - Proxy ViewModel

internal let proxyPersistenceLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyPersistence")
internal let proxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyRuntime")

enum ProxyRuntimeError: LocalizedError {
    case configurationNotFound
    case quotaServerNotFound
    case proxyStartFailed(String)
    case activationStatePersistFailed
    case deactivationStatePersistFailed
    case pricingOverridesWriteFailed
    case pricingOverridesClearFailed

    var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            return AppSettings.shared.t("The selected node could not be found.", "找不到所选节点。")
        case .quotaServerNotFound:
            return AppSettings.shared.t("QuotaServer executable not found.", "找不到 QuotaServer 可执行文件。")
        case .proxyStartFailed(let reason):
            return AppSettings.shared.t("Failed to start proxy: \(reason)", "启动代理失败：\(reason)")
        case .activationStatePersistFailed:
            return AppSettings.shared.t("The node started, but AIUsage could not persist the activated state.", "节点已启动，但 AIUsage 无法保存激活状态。")
        case .deactivationStatePersistFailed:
            return AppSettings.shared.t("The node stopped, but AIUsage could not persist the deactivated state.", "节点已停止，但 AIUsage 无法保存停用状态。")
        case .pricingOverridesWriteFailed:
            return AppSettings.shared.t("Failed to write proxy pricing overrides.", "写入代理计费覆盖失败。")
        case .pricingOverridesClearFailed:
            return AppSettings.shared.t("Failed to clear proxy pricing overrides.", "清理代理计费覆盖失败。")
        }
    }
}

class ProxyViewModel: ObservableObject {
    @Published var configurations: [ProxyConfiguration] = []
    @Published var activatedConfigId: String?
    @Published var statistics: [String: ProxyStatistics] = [:]
    @Published var recentLogs: [String: [ProxyRequestLog]] = [:]
    @Published var operationErrorMessage: String?
    @Published var operationInProgressConfigIds: Set<String> = []

    var runningProcesses: [String: Process] = [:]
    let settingsManager = ClaudeSettingsManager.shared

    var logRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: DefaultsKey.proxyLogRetentionDays)
        return days > 0 ? days : 30
    }

    var logsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-logs.json")
    }

    init() {
        loadConfigurations()
        loadStatistics()
        loadLogs()
        restoreActivatedNode()
    }

    // MARK: - Configuration Management

    func loadConfigurations() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyConfigurations) else {
            return
        }

        do {
            configurations = try JSONDecoder().decode([ProxyConfiguration].self, from: data)
        } catch {
            logPersistenceError("load proxy configurations", error: error)
        }
    }

    @discardableResult
    func saveConfigurations() -> Bool {
        do {
            let data = try JSONEncoder().encode(configurations)
            UserDefaults.standard.set(data, forKey: DefaultsKey.proxyConfigurations)
            return true
        } catch {
            logPersistenceError("save proxy configurations", error: error)
            return false
        }
    }

    func saveActivatedId() {
        UserDefaults.standard.set(activatedConfigId, forKey: DefaultsKey.proxyActivatedConfigId)
    }

    func addConfiguration(_ config: ProxyConfiguration) {
        configurations.append(config)
        if config.nodeType == .openaiProxy {
            statistics[config.id] = .empty
            recentLogs[config.id] = []
        }
        saveConfigurations()
        saveStatistics()
        saveLogs()
    }

    func updateConfiguration(_ config: ProxyConfiguration) async {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            let wasActivated = activatedConfigId == config.id
            let busyIds: Set<String> = [config.id]
            setOperationInProgress(busyIds, isActive: true)
            defer { setOperationInProgress(busyIds, isActive: false) }
            if wasActivated {
                do {
                    try await performDeactivationTransaction(config.id)
                } catch {
                    reportOperationError(error)
                    return
                }
            }
            configurations[index] = config
            saveConfigurations()
            if wasActivated {
                do {
                    try await performActivationTransaction(config.id)
                } catch {
                    reportOperationError(error)
                }
            }
        }
    }

    func deleteConfiguration(_ id: String) async {
        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }

        if activatedConfigId == id {
            do {
                try await performDeactivationTransaction(id)
            } catch {
                reportOperationError(error)
                return
            }
        }

        configurations.removeAll { $0.id == id }
        statistics.removeValue(forKey: id)
        recentLogs.removeValue(forKey: id)
        saveConfigurations()
        saveStatistics()
        saveLogs()
    }

    // MARK: - Activate / Deactivate

    func envConfig(for config: ProxyConfiguration) -> ClaudeSettingsManager.EnvConfig {
        let m = config.modelMapping
        let dm = config.defaultModel.isEmpty ? nil : config.defaultModel
        let opus   = m.bigModel.name.isEmpty    ? nil : m.bigModel.name
        let sonnet = m.middleModel.name.isEmpty ? nil : m.middleModel.name
        let haiku  = m.smallModel.name.isEmpty  ? nil : m.smallModel.name

        switch config.nodeType {
        case .anthropicDirect:
            if config.usePassthroughProxy {
                let proxyURL = "http://\(config.host):\(config.port)"
                return .init(baseURL: proxyURL, authToken: config.anthropicAPIKey,
                             defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
            }
            return .init(baseURL: config.anthropicBaseURL, authToken: config.anthropicAPIKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .openaiProxy:
            let proxyKey = config.expectedClientKey.isEmpty ? "proxy-key" : config.expectedClientKey
            return .init(baseURL: config.displayURL, authToken: proxyKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        }
    }

    func activateConfiguration(_ id: String) async {
        let busyIds = Set([id, activatedConfigId].compactMap { $0 })
        guard !busyIds.contains(where: { operationInProgressConfigIds.contains($0) }) else { return }

        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await performActivationTransaction(id)
        } catch {
            reportOperationError(error)
        }
    }

    func deactivateConfiguration(_ id: String) async {
        guard !operationInProgressConfigIds.contains(id) else { return }

        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await performDeactivationTransaction(id)
        } catch {
            reportOperationError(error)
        }
    }

    func toggleActivation(_ id: String) async {
        if activatedConfigId == id {
            await deactivateConfiguration(id)
        } else {
            await activateConfiguration(id)
        }
    }

    func performActivationTransaction(_ id: String) async throws {
        guard let config = configurations.first(where: { $0.id == id }) else {
            throw ProxyRuntimeError.configurationNotFound
        }

        if activatedConfigId == id {
            return
        }

        let previousActiveConfig = activatedConfigId.flatMap { currentId in
            configurations.first(where: { $0.id == currentId })
        }

        if let previousActiveConfig {
            try await deactivateRuntime(for: previousActiveConfig)
        }

        do {
            try await activateRuntime(for: config)
            do {
                try persistActivationSelection(config.id, touchLastUsedAt: true)
            } catch {
                do {
                    try await deactivateRuntime(for: config)
                } catch {
                    proxyRuntimeLog.error("Failed to roll back runtime for newly activated node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                if let previousActiveConfig {
                    do {
                        try await activateRuntime(for: previousActiveConfig)
                    } catch {
                        proxyRuntimeLog.error("Failed to restore previous node \(previousActiveConfig.name, privacy: .public) after persistence failure: \(String(describing: error), privacy: .public)")
                    }
                }
                throw error
            }
        } catch {
            if let previousActiveConfig {
                do {
                    try await activateRuntime(for: previousActiveConfig)
                } catch {
                    proxyRuntimeLog.error("Failed to restore previous node \(previousActiveConfig.name, privacy: .public) after activation failure: \(String(describing: error), privacy: .public)")
                }
            }
            throw error
        }

        print("✓ Node activated: \(config.name)")
    }

    func performDeactivationTransaction(_ id: String) async throws {
        guard activatedConfigId == id,
              let config = configurations.first(where: { $0.id == id }) else {
            return
        }

        try await deactivateRuntime(for: config)

        do {
            try persistActivationSelection(nil, touchLastUsedAt: false)
        } catch {
            do {
                try await activateRuntime(for: config)
            } catch {
                proxyRuntimeLog.error("Failed to restore node \(config.name, privacy: .public) after deactivation persistence failure: \(String(describing: error), privacy: .public)")
            }
            throw error
        }

        print("✓ Node deactivated: \(config.name)")
    }

    func persistActivationSelection(_ activeId: String?, touchLastUsedAt: Bool) throws {
        let previousConfigurations = configurations
        let previousActivatedConfigId = activatedConfigId
        let now = touchLastUsedAt ? Date() : nil

        activatedConfigId = activeId
        for index in configurations.indices {
            let isActive = configurations[index].id == activeId
            configurations[index].isEnabled = isActive
            if isActive, let now {
                configurations[index].lastUsedAt = now
            }
        }

        guard saveConfigurations() else {
            configurations = previousConfigurations
            activatedConfigId = previousActivatedConfigId
            if activeId == nil {
                throw ProxyRuntimeError.deactivationStatePersistFailed
            }
            throw ProxyRuntimeError.activationStatePersistFailed
        }

        saveActivatedId()
    }

    func setOperationInProgress(_ ids: Set<String>, isActive: Bool) {
        if isActive {
            operationInProgressConfigIds.formUnion(ids)
        } else {
            operationInProgressConfigIds.subtract(ids)
        }
    }

    func isOperationInProgress(_ configId: String) -> Bool {
        operationInProgressConfigIds.contains(configId)
    }

    func reportOperationError(_ error: Error) {
        let redactedMessage = SensitiveDataRedactor.redactedMessage(for: error)
        operationErrorMessage = redactedMessage
        proxyRuntimeLog.error("Proxy operation failed: \(redactedMessage, privacy: .public)")
    }

    func logPersistenceError(_ action: String, error: Error) {
        proxyPersistenceLog.error("Failed to \(action, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}

// MARK: - QuotaServer discovery
// `#filePath` must stay in ProxyViewModel.swift so DerivedData / workspace resolution matches prior builds.

extension ProxyViewModel {
    private static let sourceFileDir: String = {
        let filePath = #filePath
        return (filePath as NSString).deletingLastPathComponent
    }()

    func findQuotaServerExecutable() -> String? {
        let fileManager = FileManager.default

        // Strategy 1: derive from #filePath (compile-time source location)
        let sourceProjectRoot = (Self.sourceFileDir as NSString)
            .deletingLastPathComponent
        let projectRootFromSource = (sourceProjectRoot as NSString)
            .deletingLastPathComponent

        // Strategy 2: derive from Bundle.main.bundleURL for Xcode DerivedData builds
        // e.g., .../DerivedData/.../Debug/AIUsage.app -> walk up to find workspace
        let bundlePath = Bundle.main.bundlePath

        let candidateRoots = [
            projectRootFromSource,
            bundlePath,
        ]

        let relativePaths = [
            "QuotaBackend/.build/debug/QuotaServer",
            "QuotaBackend/.build/release/QuotaServer",
        ]

        // Try each candidate root
        for root in candidateRoots {
            for relPath in relativePaths {
                let fullPath = (root as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    print("Found QuotaServer at: \(fullPath)")
                    return fullPath
                }
            }
        }

        // Strategy 3: walk up from source root looking for QuotaBackend
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
