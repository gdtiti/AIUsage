import Foundation
import Combine
import QuotaBackend
import os.log

private let providerActivationLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderActivation")

// MARK: - Provider Account Activation
// Manages CLI auth file switching for Codex and Gemini: detection from disk,
// activation from managed/proxy sources, format normalization, and UserDefaults persistence.

final class ProviderActivationManager: ObservableObject {
    static let shared = ProviderActivationManager()

    static let activatableProviders: Set<String> = ["codex", "gemini"]

    @Published var activeProviderAccountIds: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.activeProviderAccountIds) else {
            if let legacyCodex = UserDefaults.standard.string(forKey: DefaultsKey.activeCodexAccountId) {
                return ["codex": legacyCodex]
            }
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            providerActivationLog.error("Failed to decode persisted active provider ids: \(String(describing: error), privacy: .public)")
            if let legacyCodex = UserDefaults.standard.string(forKey: DefaultsKey.activeCodexAccountId) {
                return ["codex": legacyCodex]
            }
            return [:]
        }
    }()

    @Published var activationResult: ActivationResult?
    @Published var codexActivationResult: CodexActivationResult?

    let accountStore = AccountStore.shared
    let settings = AppSettings.shared

    var activeCodexAccountId: String? {
        get { activeProviderAccountIds["codex"] }
        set {
            activeProviderAccountIds["codex"] = newValue
            persistActiveIds()
        }
    }

    enum CodexActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    enum ActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    private init() {}

    private func persistActiveIds() {
        do {
            let data = try JSONEncoder().encode(activeProviderAccountIds)
            UserDefaults.standard.set(data, forKey: DefaultsKey.activeProviderAccountIds)
        } catch {
            providerActivationLog.error("Failed to persist active provider ids: \(String(describing: error), privacy: .public)")
        }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        Self.activatableProviders.contains(providerId)
    }

    func activateAccount(entry: ProviderAccountEntry) throws {
        switch entry.providerId {
        case "codex":
            try activateCodexAccount(entry: entry)
        case "gemini":
            try activateGeminiAccount(entry: entry)
        default:
            break
        }
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        guard let activeId = activeProviderAccountIds[entry.providerId]?.lowercased() else { return false }

        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            let entryPath = entry.storedAccount?.sourceFilePath ?? entry.liveProvider?.sourceFilePath
            guard let entryPath else { return false }
            return AccountCredentialStore.normalizedAuthFilePath(entryPath) == activeId
        }

        let entryAccountId = (entry.storedAccount?.accountId ?? entry.liveProvider?.accountId)?.lowercased().nilIfBlank
        if let entryAccountId {
            return entryAccountId == activeId
        }

        let email = entry.accountEmail?.lowercased().nilIfBlank
        return email != nil && email == activeId
    }

    func isActiveCodexAccount(_ entry: ProviderAccountEntry) -> Bool {
        isActiveAccount(entry)
    }

    // MARK: Codex activation

    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let codexDir = NSString(string: "~/.codex").expandingTildeInPath
        let targetPath = "\(codexDir)/auth.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel
        let accountId = entry.storedAccount?.accountId
            ?? entry.liveProvider?.accountId

        let resolved = resolveCliProxyOrManagedSource(prefix: "codex", email: email, entry: entry)
        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToCodexNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: nativeData, fm: fm)

        let entryPath = entry.storedAccount?.sourceFilePath ?? entry.liveProvider?.sourceFilePath
        if let entryPath {
            activeProviderAccountIds["codex"] = AccountCredentialStore.normalizedAuthFilePath(entryPath)
        } else {
            activeProviderAccountIds["codex"] = accountId ?? email
        }
        persistActiveIds()

        let label = email ?? accountId ?? "Codex"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
        codexActivationResult = .success(msg)
    }

    // MARK: Gemini / Antigravity activation

    func activateGeminiAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let geminiDir = NSString(string: "~/.gemini").expandingTildeInPath
        let oauthCredsPath = "\(geminiDir)/oauth_creds.json"
        let googleAccountsPath = "\(geminiDir)/google_accounts.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel

        let proxyPrefix = entry.providerId == "antigravity" ? "antigravity" : "gemini"
        let resolved = resolveCliProxyOrManagedSource(prefix: proxyPrefix, email: email, entry: entry)

        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToGeminiNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: geminiDir, targetPath: oauthCredsPath, data: nativeData, fm: fm)

        if let email {
            try updateGeminiActiveAccount(googleAccountsPath: googleAccountsPath, email: email, fm: fm)
        }

        activeProviderAccountIds["gemini"] = email
        persistActiveIds()

        let label = email ?? "Account"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
    }

    private func convertToGeminiNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["refresh_token"] != nil, json["scope"] != nil {
            return data
        }

        if let tokenDict = json["token"] as? [String: Any], let refreshToken = tokenDict["refresh_token"] as? String {
            var native: [String: Any] = [
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
            ]
            if let accessToken = tokenDict["access_token"] as? String { native["access_token"] = accessToken }
            if let idToken = tokenDict["id_token"] as? String { native["id_token"] = idToken }
            if let expiryDate = tokenDict["expiry_date"] as? Int { native["expiry_date"] = expiryDate }
            if let clientId = tokenDict["client_id"] as? String { native["client_id"] = clientId }
            if let clientSecret = tokenDict["client_secret"] as? String { native["client_secret"] = clientSecret }
            if let email = json["email"] as? String { native["email"] = email }
            return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
        }

        if let refreshToken = json["refresh_token"] as? String {
            var native: [String: Any] = [
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
            ]
            if let accessToken = json["access_token"] as? String { native["access_token"] = accessToken }
            if let idToken = json["id_token"] as? String { native["id_token"] = idToken }
            if let expiryDate = json["expiry_date"] as? Int { native["expiry_date"] = expiryDate }
            if let clientId = json["client_id"] as? String { native["client_id"] = clientId }
            if let clientSecret = json["client_secret"] as? String { native["client_secret"] = clientSecret }
            if let email = json["email"] as? String { native["email"] = email }
            return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
        }

        return data
    }

    private func updateGeminiActiveAccount(googleAccountsPath: String, email: String, fm: FileManager) throws {
        var accounts: [String: Any]
        if let data = fm.contents(atPath: googleAccountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accounts = json
        } else {
            accounts = [:]
        }

        let previousActive = accounts["active"] as? String
        var oldList = (accounts["old"] as? [String]) ?? []

        if let previousActive, previousActive != email, !oldList.contains(previousActive) {
            oldList.append(previousActive)
        }
        oldList.removeAll { $0 == email }

        accounts["active"] = email
        accounts["old"] = oldList

        let data = try JSONSerialization.data(withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: googleAccountsPath), options: .atomic)
    }

    // MARK: Codex format conversion

    private func convertToCodexNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return data
        }

        var native: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": json["account_id"] ?? "",
                "id_token": json["id_token"] ?? ""
            ] as [String: Any],
            "last_refresh": json["last_refresh"] ?? SharedFormatters.iso8601String(from: Date())
        ]
        if let email = json["email"] as? String, !email.isEmpty {
            native["email"] = email
        }
        native["OPENAI_API_KEY"] = NSNull()

        return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Shared helpers

    private func writeAuthFileWithBackup(targetDir: String, targetPath: String, data: Data, fm: FileManager) throws {
        if !fm.fileExists(atPath: targetDir) {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        let backupPath = "\(targetPath).bak"
        if fm.fileExists(atPath: targetPath) {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: targetPath, toPath: backupPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            if fm.fileExists(atPath: backupPath) {
                try? fm.removeItem(atPath: targetPath)
                try? fm.copyItem(atPath: backupPath, toPath: targetPath)
            }
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            let msg = settings.t("Switch failed: \(redactedError)", "切换失败：\(redactedError)")
            activationResult = .failure(msg)
            throw error
        }
    }

    private func resolveCliProxyOrManagedSource(prefix: String, email: String?, entry: ProviderAccountEntry) -> String? {
        let fm = FileManager.default

        let credentials = accountStore.matchingCredentials(for: entry)
        if let credential = credentials.first {
            let candidatePaths: [String?] = [
                credential.authMethod == .authFile ? credential.credential : nil,
                credential.metadata["sourcePath"]
            ]
            for p in candidatePaths.compactMap({ $0?.nilIfBlank }) {
                let expanded = NSString(string: p).expandingTildeInPath
                if fm.fileExists(atPath: expanded) { return expanded }
            }
        }

        let proxyDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        let entryAccountId = entry.storedAccount?.accountId ?? entry.liveProvider?.accountId

        if let email {
            if let entryAccountId,
               let exactPath = proxyFileMatchingAccountId(dir: proxyDir, prefix: prefix, email: email, accountId: entryAccountId, fm: fm) {
                return exactPath
            }
            if let freshPath = freshestCliProxyFile(dir: proxyDir, prefix: prefix, email: email, fm: fm) {
                return freshPath
            }
        }

        return nil
    }

    private func freshestCliProxyFile(dir: String, prefix: String, email: String, fm: FileManager) -> String? {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let emailLower = email.lowercased()
        let matching = files.filter {
            $0.hasPrefix("\(prefix)-") && $0.hasSuffix(".json") && $0.lowercased().contains(emailLower)
        }
        guard !matching.isEmpty else { return nil }

        var best: (path: String, date: Date)?
        for file in matching {
            let fullPath = "\(dir)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if let current = best, modDate > current.date {
                best = (fullPath, modDate)
            } else if best == nil {
                best = (fullPath, modDate)
            }
        }
        return best?.path
    }

    private func proxyFileMatchingAccountId(dir: String, prefix: String, email: String, accountId: String, fm: FileManager) -> String? {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let emailLower = email.lowercased()
        let rawAccountId = accountId.lowercased().components(separatedBy: ":").first ?? accountId.lowercased()
        let matching = files.filter {
            $0.hasPrefix("\(prefix)-") && $0.hasSuffix(".json") && $0.lowercased().contains(emailLower)
        }
        for file in matching {
            let fullPath = "\(dir)/\(file)"
            guard let data = fm.contents(atPath: fullPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let fileAccountId = (json["account_id"] as? String)?.lowercased()
                ?? ((json["tokens"] as? [String: Any])?["account_id"] as? String)?.lowercased()
            if fileAccountId == rawAccountId { return fullPath }
        }
        return nil
    }

    // MARK: Detection

    private func applyDetectedActiveId(_ detectedId: String?, for providerId: String, reason: String) {
        let normalizedDetectedId = detectedId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let previousDetectedId = activeProviderAccountIds[providerId]

        if let normalizedDetectedId {
            guard normalizedDetectedId != previousDetectedId else { return }
            activeProviderAccountIds[providerId] = normalizedDetectedId
            persistActiveIds()
            return
        }

        guard previousDetectedId != nil else { return }
        activeProviderAccountIds.removeValue(forKey: providerId)
        persistActiveIds()
        providerActivationLog.info("Cleared active \(providerId, privacy: .public) account detection: \(reason, privacy: .public)")
    }

    private func jwtEmailFromToken(_ token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let email = claims["email"] as? String else {
            return nil
        }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func detectActiveCodexAccount() {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath) else {
            applyDetectedActiveId(nil, for: "codex", reason: "auth file missing")
            return
        }

        let normalizedPath = AccountCredentialStore.normalizedAuthFilePath(authPath)
        let codexAccounts = accountStore.accountRegistry.filter { $0.providerId == "codex" }

        if let match = codexAccounts.first(where: {
            AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, authPath)
        }) {
            applyDetectedActiveId(normalizedPath, for: "codex", reason: "matched by sourceFilePath")
            return
        }

        let credentials = AccountCredentialStore.shared.loadCredentials(for: "codex")
        if let credMatch = credentials.first(where: { cred in
            guard cred.authMethod == .authFile else { return false }
            let sourcePath = cred.metadata["sourcePath"]?.nilIfBlank ?? cred.credential
            return AccountCredentialStore.normalizedAuthFilePath(sourcePath) == normalizedPath
        }) {
            if let storedMatch = codexAccounts.first(where: { $0.credentialId == credMatch.id }) {
                let storedPath = storedMatch.sourceFilePath.flatMap {
                    AccountCredentialStore.normalizedAuthFilePath($0)
                } ?? normalizedPath
                applyDetectedActiveId(storedPath, for: "codex", reason: "matched managed credential")
                return
            }
        }
    }

    private static func loadJSON(atPath path: String) -> [String: Any]? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func detectActiveGeminiAccount() {
        let googleAccountsPath = NSString(string: "~/.gemini/google_accounts.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: googleAccountsPath) else {
            applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json missing")
            return
        }

        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json root object is not a dictionary")
                return
            }
            json = object
        } catch {
            providerActivationLog.error("Failed to decode Gemini google_accounts.json: \(String(describing: error), privacy: .public)")
            applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json contains invalid JSON")
            return
        }

        let active = (json["active"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        applyDetectedActiveId(active, for: "gemini", reason: "google_accounts.json has no active account")
    }
}
