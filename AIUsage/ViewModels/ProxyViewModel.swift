import SwiftUI
import Combine
import Foundation
import QuotaBackend

// MARK: - Proxy ViewModel

class ProxyViewModel: ObservableObject {
    @Published var configurations: [ProxyConfiguration] = []
    @Published var activatedConfigId: String?
    @Published var statistics: [String: ProxyStatistics] = [:]
    @Published var recentLogs: [String: [ProxyRequestLog]] = [:]

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
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyConfigurations),
           let configs = try? JSONDecoder().decode([ProxyConfiguration].self, from: data) {
            configurations = configs
        }
    }

    func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.proxyConfigurations)
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

    func updateConfiguration(_ config: ProxyConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            let wasActivated = activatedConfigId == config.id
            if wasActivated {
                deactivateConfiguration(config.id)
            }
            configurations[index] = config
            saveConfigurations()
            if wasActivated {
                activateConfiguration(config.id)
            }
        }
    }

    func deleteConfiguration(_ id: String) {
        if activatedConfigId == id {
            deactivateConfiguration(id)
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

    func activateConfiguration(_ id: String) {
        guard let config = configurations.first(where: { $0.id == id }) else { return }

        if let currentId = activatedConfigId, currentId != id {
            deactivateConfiguration(currentId)
        }

        if config.needsProxyProcess {
            startProxy(config)
        }
        settingsManager.writeEnv(envConfig(for: config))
        writePricingOverrides(config)

        activatedConfigId = id
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = true
            configurations[index].lastUsedAt = Date()
        }
        saveConfigurations()
        saveActivatedId()
        print("✓ Node activated: \(config.name)")
    }

    func deactivateConfiguration(_ id: String) {
        guard let config = configurations.first(where: { $0.id == id }) else { return }

        if config.needsProxyProcess {
            stopProxy(config)
        }

        settingsManager.clearEnv()
        clearPricingOverrides()

        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = false
        }
        activatedConfigId = nil
        saveConfigurations()
        saveActivatedId()
        print("✓ Node deactivated: \(config.name)")
    }

    func toggleActivation(_ id: String) {
        if activatedConfigId == id {
            deactivateConfiguration(id)
        } else {
            activateConfiguration(id)
        }
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

        // Fallback: try to build
        let quotaBackendDir = (projectRootFromSource as NSString).appendingPathComponent("QuotaBackend")
        guard fileManager.fileExists(atPath: (quotaBackendDir as NSString).appendingPathComponent("Package.swift")) else {
            print("✗ QuotaBackend package not found at: \(quotaBackendDir)")
            print("  #filePath resolved to: \(Self.sourceFileDir)")
            print("  Bundle.main.bundlePath: \(bundlePath)")
            return nil
        }

        print("QuotaServer not found, attempting to build...")
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["build", "--product", "QuotaServer"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: quotaBackendDir)

        do {
            try buildProcess.run()
            buildProcess.waitUntilExit()

            if buildProcess.terminationStatus == 0 {
                for relPath in relativePaths {
                    let fullPath = (projectRootFromSource as NSString).appendingPathComponent(relPath)
                    if fileManager.fileExists(atPath: fullPath) {
                        print("Built and found QuotaServer at: \(fullPath)")
                        return fullPath
                    }
                }
            } else {
                print("Build failed with status: \(buildProcess.terminationStatus)")
            }
        } catch {
            print("Failed to build QuotaServer: \(error)")
        }

        return nil
    }
}
