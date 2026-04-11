import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import QuotaBackend

private func aiusageDefaultCLIPath() -> String {
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

private func aiusageResolvedExecutable(named executable: String) -> String? {
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

private final class WeakCodexCoordinatorBox: @unchecked Sendable {
    weak var value: CodexLoginCoordinator?

    init(_ value: CodexLoginCoordinator) {
        self.value = value
    }
}

struct ProviderAuthPlan {
    let titleEn: String
    let titleZh: String
    let summaryEn: String
    let summaryZh: String
    let launchActions: [ProviderAuthLaunchAction]
    let supportsEmbeddedWebLogin: Bool
}

struct ProviderAuthLaunchAction: Identifiable, Hashable {
    enum Kind: Hashable {
        case openApp(bundleIdentifier: String)
        case openURL(URL)
        case revealPath(String)
        case runTerminal(command: String)
    }

    let id: String
    let titleEn: String
    let titleZh: String
    let subtitleEn: String
    let subtitleZh: String
    let kind: Kind

    func title(for language: String) -> String {
        language == "zh" ? titleZh : titleEn
    }

    func subtitle(for language: String) -> String {
        language == "zh" ? subtitleZh : subtitleEn
    }
}

struct ProviderAuthCandidate: Identifiable, Hashable {
    enum IdentityScope: String, Hashable {
        case accountScoped
        case sharedSource
    }

    let id: String
    let providerId: String
    let sourceIdentifier: String
    let sessionFingerprint: String?
    let title: String
    let subtitle: String?
    let detail: String
    let modifiedAt: Date?
    let authMethod: AuthMethod
    let credentialValue: String
    let sourcePath: String?
    let shouldCopyFile: Bool
    let identityScope: IdentityScope
}

struct ProviderMonitoredSessionIndex {
    let sourceIdentifiers: Set<String>
    let sessionFingerprints: Set<String>
    let accountHandles: Set<String>
}

enum ProviderManagedImportStore {
    private static let rootPathComponent = "/Library/Application Support/AIUsage/AuthImports/"

    static func isManagedImportPath(_ path: String?) -> Bool {
        guard let path = path?.nilIfBlank else { return false }
        return canonicalManagedPath(path) != nil
    }

    static func primaryManagedImportPath(for credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile,
           let credentialPath = canonicalManagedPath(credential.credential) {
            return credentialPath
        }

        return canonicalManagedPath(credential.metadata["sourcePath"])
    }

    static func managedImportPaths(for credential: AccountCredential) -> Set<String> {
        Set(
            [credential.credential, credential.metadata["sourcePath"]]
                .compactMap { canonicalManagedPath($0) }
        )
    }

    static func reuseManagedImportIfPossible(existingCredential: AccountCredential, incomingCredential: inout AccountCredential) {
        guard incomingCredential.authMethod == .authFile,
              let existingPath = primaryManagedImportPath(for: existingCredential),
              let incomingPath = primaryManagedImportPath(for: incomingCredential),
              existingPath != incomingPath else {
            return
        }

        do {
            try replaceManagedImport(at: existingPath, withContentsOf: incomingPath)
            removeManagedImport(at: incomingPath)
            let preservedLastUsedAt = incomingCredential.lastUsedAt

            if canonicalManagedPath(incomingCredential.credential) != nil {
                incomingCredential = AccountCredential(
                    id: incomingCredential.id,
                    providerId: incomingCredential.providerId,
                    accountLabel: incomingCredential.accountLabel,
                    authMethod: incomingCredential.authMethod,
                    credential: existingPath,
                    metadata: incomingCredential.metadata
                )
                incomingCredential.lastUsedAt = preservedLastUsedAt
            }

            if let sourcePath = incomingCredential.metadata["sourcePath"],
               canonicalManagedPath(sourcePath) == incomingPath {
                incomingCredential.metadata["sourcePath"] = existingPath
            }
        } catch {
            // If artifact reuse fails, keep the newer copied file and let
            // periodic orphan cleanup handle any stale leftovers.
        }
    }

    static func cleanupOrphanedManagedImports(referencedBy credentials: [AccountCredential]) {
        guard let rootDirectory = try? managedImportsRootDirectory(),
              FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return
        }

        let referencedPaths = Set(credentials.flatMap { managedImportPaths(for: $0) })
        guard !referencedPaths.isEmpty else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            if !referencedPaths.contains(path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        pruneEmptyDirectories(under: rootDirectory)
    }

    private static func replaceManagedImport(at targetPath: String, withContentsOf sourcePath: String) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: targetURL, options: .atomic)
    }

    private static func removeManagedImport(at path: String) {
        guard let managedPath = canonicalManagedPath(path) else { return }
        try? FileManager.default.removeItem(atPath: managedPath)
    }

    private static func managedImportsRootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("AuthImports", isDirectory: true)
    }

    private static func canonicalManagedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfBlank else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return canonical.contains(rootPathComponent) ? canonical : nil
    }

    private static func pruneEmptyDirectories(under rootDirectory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return
        }

        let directories = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path.count > $1.path.count }

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  directory != rootDirectory,
                  let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ),
                  contents.isEmpty else {
                continue
            }

            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
final class CodexLoginCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case launching
        case waitingForBrowser
        case waitingForCompletion
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var authURL: URL?
    @Published private(set) var callbackURL: URL?
    @Published private(set) var outputSummary: String?
    @Published private(set) var importedAuthFileURL: URL?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var outputBuffer = ""
    private var didSeeAuthURL = false
    private var sessionDirectoryURL: URL?
    private var completionTask: Task<Void, Never>?
    private var hasCompletedLogin = false
    private var loginStartedAt: Date?
    private var baselineCandidateSignatures: Set<String> = []

    var isRunning: Bool {
        switch phase {
        case .launching, .waitingForBrowser, .waitingForCompletion:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    func start() {
        cancel()

        phase = .launching
        authURL = nil
        callbackURL = nil
        outputSummary = nil
        importedAuthFileURL = nil
        outputBuffer = ""
        didSeeAuthURL = false
        hasCompletedLogin = false
        loginStartedAt = Date()
        baselineCandidateSignatures = Set(ProviderAuthManager.codexCandidates().map(Self.candidateSignature(for:)))
        completionTask?.cancel()
        completionTask = nil

        let fileManager = FileManager.default
        let sessionDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-codex-login-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Failed to prepare a secure Codex login session: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return
        }

        sessionDirectoryURL = sessionDirectory

        guard let codexExecutable = aiusageResolvedExecutable(named: "codex") else {
            cleanup(removeArtifacts: true)
            phase = .failed("AIUsage could not find the Codex CLI. Install `@openai/codex` first.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", codexExecutable, "login"]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = sessionDirectory.path
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = [
            environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            aiusageDefaultCLIPath()
        ]
        .compactMap { $0 }
        .joined(separator: ":")
        process.environment = environment

        let weakBox = WeakCodexCoordinatorBox(self)

        pipe.fileHandleForReading.readabilityHandler = { [weak weakBox] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                weakBox?.value?.consumeOutput(text)
            }
        }

        process.terminationHandler = { [weak weakBox] terminated in
            DispatchQueue.main.async {
                weakBox?.value?.finish(status: terminated.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = pipe
            outputSummary = "Codex login started."
            beginWaitingForAuthFile()
        } catch {
            cleanup(removeArtifacts: true)
            phase = .failed("Failed to start Codex login: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    func cancel() {
        completionTask?.cancel()
        completionTask = nil
        hasCompletedLogin = false
        loginStartedAt = nil
        baselineCandidateSignatures = []
        if let process, process.isRunning {
            process.terminate()
        }
        cleanup(removeArtifacts: true)
        phase = .idle
    }

    func discardImportedSession() {
        cleanup(removeArtifacts: true)
    }

    private func consumeOutput(_ text: String) {
        outputBuffer += text
        let sanitized = Self.sanitizedOutput(outputBuffer)

        if callbackURL == nil {
            callbackURL = Self.firstURL(in: sanitized, matchingHost: "localhost")
        }

        if let callbackURL, Self.isSuccessfulCallbackURL(callbackURL) {
            phase = .waitingForCompletion
            outputSummary = "Codex login approved. Finalizing account…"
            beginWaitingForAuthFile()
        }

        if authURL == nil {
            authURL = Self.firstURL(in: sanitized, matchingHost: "auth.openai.com")
        }

        if authURL != nil {
            if !didSeeAuthURL {
                phase = .waitingForBrowser
                didSeeAuthURL = true
            } else {
                phase = .waitingForCompletion
            }
        }

        if let summary = Self.humanSummary(from: sanitized) {
            outputSummary = summary
        }
    }

    func noteBrowserNavigation(_ url: URL) {
        callbackURL = url

        guard Self.isSuccessfulCallbackURL(url) else { return }

        phase = .waitingForCompletion
        outputSummary = "Codex login approved. Finalizing account…"
        beginWaitingForAuthFile()
    }

    private func finish(status: Int32) {
        completionTask?.cancel()
        completionTask = nil

        if hasCompletedLogin {
            cleanup(removeArtifacts: false)
            return
        }

        let sanitized = Self.sanitizedOutput(outputBuffer)
        let authFileURL = currentAuthFileURL()
        cleanup(removeArtifacts: status == 0 && authFileURL != nil ? false : true)

        if status == 0 {
            guard let authFileURL else {
                if let callbackURL, Self.isSuccessfulCallbackURL(callbackURL) {
                    phase = .waitingForCompletion
                    outputSummary = "Codex login approved. Finalizing account…"
                    beginWaitingForAuthFileAfterExit()
                    return
                }

                phase = .failed("Codex login finished, but AIUsage could not find the new auth file.")
                outputSummary = Self.humanSummary(from: sanitized)
                    ?? "Codex login finished, but no auth file was produced."
                return
            }
            importedAuthFileURL = authFileURL
            phase = .succeeded
            outputSummary = Self.humanSummary(from: sanitized) ?? "Codex login completed."
            return
        }

        if let callbackURL, Self.isSuccessfulCallbackURL(callbackURL) {
            phase = .waitingForCompletion
            outputSummary = "Codex login approved. Finalizing account…"
            beginWaitingForAuthFileAfterExit()
            return
        }

        let message = Self.failureMessage(from: sanitized)
            ?? "Codex login exited before authentication completed."
        phase = .failed(message)
        outputSummary = message
    }

    private func beginWaitingForAuthFile() {
        guard completionTask == nil, !hasCompletedLogin else { return }

        completionTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }

                if let authFileURL = self.currentAuthFileURL() {
                    self.completeLogin(with: authFileURL)
                    return
                }
            }
        }
    }

    private func beginWaitingForAuthFileAfterExit() {
        guard completionTask == nil, !hasCompletedLogin else { return }

        completionTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }

                if let authFileURL = self.currentAuthFileURL() {
                    self.completeLogin(with: authFileURL)
                    return
                }
            }

            self.phase = .failed("Codex login finished, but AIUsage still could not find the new auth file.")
            self.outputSummary = "Codex login finished, but the refreshed auth file never appeared."
        }
    }

    private func currentAuthFileURL() -> URL? {
        if let isolatedAuthFile = Self.locateAuthFile(in: sessionDirectoryURL) {
            return isolatedAuthFile
        }

        guard let loginStartedAt else { return nil }
        let threshold = loginStartedAt.addingTimeInterval(-1)
        let defaultPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath

        let candidates = ProviderAuthManager.codexCandidates()
            .filter { candidate in
                if !baselineCandidateSignatures.contains(Self.candidateSignature(for: candidate)) {
                    return true
                }
                return (candidate.modifiedAt ?? .distantPast) >= threshold
            }
            .sorted { lhs, rhs in
                if lhs.sourcePath == defaultPath, rhs.sourcePath != defaultPath { return true }
                if rhs.sourcePath == defaultPath, lhs.sourcePath != defaultPath { return false }
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }

        guard let sourcePath = candidates.first?.sourcePath?.nilIfBlank else { return nil }
        return URL(fileURLWithPath: sourcePath)
    }

    private func completeLogin(with authFileURL: URL) {
        guard !hasCompletedLogin else { return }

        hasCompletedLogin = true
        importedAuthFileURL = authFileURL
        phase = .succeeded
        outputSummary = outputSummary ?? "Codex login completed."

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil

        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func cleanup(removeArtifacts: Bool) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
        if removeArtifacts, let sessionDirectoryURL {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            self.sessionDirectoryURL = nil
            importedAuthFileURL = nil
        }
    }

    private static func sanitizedOutput(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{8}", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("^D") }
            .joined(separator: "\n")
    }

    private static func firstURL(in text: String, matchingHost host: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first(where: { $0.host?.contains(host) == true })
    }

    private static func humanSummary(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("Starting local login server") }) {
            return line
        }
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("If your browser did not open") }) {
            return line
        }
        return lines.last
    }

    private static func failureMessage(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        return lines.last(where: { !$0.isEmpty })
    }

    private static func isSuccessfulCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.contains("localhost") || host.contains("127.0.0.1") else {
            return false
        }

        let path = url.path.lowercased()
        if path.contains("success") || path.contains("callback") {
            return true
        }

        let queryNames = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            $0.name.lowercased()
        })
        return queryNames.contains("id_token")
            || queryNames.contains("access_token")
            || queryNames.contains("code")
    }

    private static func locateAuthFile(in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let fileManager = FileManager.default

        let directFile = directory.appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: directFile.path) {
            return directFile
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "auth.json" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }

    private static func candidateSignature(for candidate: ProviderAuthCandidate) -> String {
        [
            candidate.sourcePath ?? candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            String(Int(candidate.modifiedAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: "|")
    }

    var startedAt: Date? {
        loginStartedAt
    }
}

@MainActor
final class GeminiLoginCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case launching
        case waitingForBrowser
        case waitingForCompletion
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var authURL: URL?
    @Published private(set) var callbackURL: URL?
    @Published private(set) var outputSummary: String?
    @Published private(set) var importedAuthFileURL: URL?
    @Published private(set) var accountEmail: String?

    private struct OAuthConfiguration {
        let clientId: String
        let clientSecret: String
    }

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!

    private let listenerQueue = DispatchQueue(label: "AIUsage.GeminiOAuth")
    private var listener: NWListener?
    private var timeoutTask: Task<Void, Never>?
    private var sessionDirectoryURL: URL?
    private var redirectURL: URL?
    private var stateToken: String?
    private var oauthConfiguration: OAuthConfiguration?
    private var didFinish = false

    var isRunning: Bool {
        switch phase {
        case .launching, .waitingForBrowser, .waitingForCompletion:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    func start() {
        cancel()

        phase = .launching
        authURL = nil
        callbackURL = nil
        outputSummary = "Preparing Google sign-in…"
        importedAuthFileURL = nil
        accountEmail = nil
        didFinish = false

        let fileManager = FileManager.default
        let sessionDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-gemini-login-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Failed to prepare a Gemini login session: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return
        }

        sessionDirectoryURL = sessionDirectory

        guard let oauthConfiguration = Self.resolveOAuthConfiguration() else {
            cleanup(removeArtifacts: true)
            phase = .failed("AIUsage could not find Gemini CLI OAuth configuration. Reinstall Gemini CLI or set AIUSAGE_GEMINI_OAUTH_CLIENT_ID / AIUSAGE_GEMINI_OAUTH_CLIENT_SECRET.")
            return
        }
        self.oauthConfiguration = oauthConfiguration

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.accept(connection)
                }
            }

            listener.start(queue: listenerQueue)
        } catch {
            cleanup(removeArtifacts: true)
            phase = .failed("Failed to start the Gemini sign-in callback server: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        redirectURL = nil
        stateToken = nil
        oauthConfiguration = nil
        didFinish = false
        cleanup(removeArtifacts: true)
        phase = .idle
    }

    func discardImportedSession() {
        cleanup(removeArtifacts: true)
    }

    func reopenInBrowser() {
        guard let authURL else { return }
        NSWorkspace.shared.open(authURL)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let listener,
                  let port = listener.port?.rawValue,
                  let oauthConfiguration else {
                phase = .failed("Gemini sign-in could not determine its callback port.")
                cleanup(removeArtifacts: true)
                return
            }

            let stateToken = Self.randomStateToken()
            self.stateToken = stateToken
            let redirectURL = URL(string: "http://127.0.0.1:\(port)/oauth2callback")!
            self.redirectURL = redirectURL
            self.authURL = Self.makeAuthURL(
                clientId: oauthConfiguration.clientId,
                redirectURL: redirectURL,
                stateToken: stateToken
            )

            phase = .waitingForBrowser
            outputSummary = "Google sign-in opened in your browser. Finish authentication and AIUsage will connect the account automatically."
            if let authURL {
                NSWorkspace.shared.open(authURL)
            }
            beginTimeout()
        case .failed(let error):
            phase = .failed("Gemini sign-in listener failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
            cleanup(removeArtifacts: true)
        default:
            break
        }
    }

    private func beginTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled, !didFinish else { return }
            self.phase = .failed("Gemini authentication timed out after 5 minutes. Please try again.")
            self.cleanup(removeArtifacts: true)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: listenerQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    self.phase = .failed("Gemini callback failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
                }
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty,
                  let request = String(data: data, encoding: .utf8),
                  let requestURL = Self.extractRequestURL(from: request) else {
                self.respond(
                    on: connection,
                    html: Self.failureHTML(message: "AIUsage could not read the Gemini sign-in callback.")
                )
                return
            }

            Task { @MainActor in
                await self.handleCallback(requestURL, connection: connection)
            }
        }
    }

    private func handleCallback(_ url: URL, connection: NWConnection) async {
        callbackURL = url

        guard Self.isSuccessfulCallbackURL(url) else {
            respond(
                on: connection,
                html: Self.failureHTML(message: "Unexpected Gemini callback URL.")
            )
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let queryValue: (String) -> String? = { name in
            queryItems.first(where: { $0.name == name })?.value
        }

        if let errorCode = queryValue("error") {
            let description = queryValue("error_description") ?? "No additional details provided."
            let message = "Google OAuth error: \(errorCode). \(description)"
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
            return
        }

        guard queryValue("state") == stateToken else {
            let message = "Gemini OAuth state mismatch. Please try again."
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
            return
        }

        guard let code = queryValue("code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            let message = "No authorization code was returned by Google OAuth."
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
            return
        }

        phase = .waitingForCompletion
        outputSummary = "Google sign-in approved. Finalizing Gemini account…"

        do {
            let (authFileURL, email) = try await finalizeLogin(usingAuthorizationCode: code)
            accountEmail = email
            importedAuthFileURL = authFileURL
            didFinish = true
            phase = .succeeded
            outputSummary = email?.isEmpty == false
                ? "Gemini account connected for \(email!)."
                : "Gemini account connected."

            respond(on: connection, html: Self.successHTML(email: email))
            timeoutTask?.cancel()
            timeoutTask = nil
            listener?.cancel()
            listener = nil
        } catch {
            let message = SensitiveDataRedactor.redactedMessage(for: error)
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
        }
    }

    private func finalizeLogin(usingAuthorizationCode code: String) async throws -> (URL, String?) {
        guard let oauthConfiguration,
              let redirectURL,
              let sessionDirectoryURL else {
            throw ProviderError("oauth_setup_failed", "Gemini OAuth session was not fully initialized.")
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: oauthConfiguration.clientId),
            URLQueryItem(name: "client_secret", value: oauthConfiguration.clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError("oauth_exchange_failed", "Gemini OAuth token exchange failed (\(http.statusCode)). \(payload)")
        }

        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["access_token"] as? String != nil else {
            throw ProviderError("oauth_exchange_failed", "Gemini OAuth token exchange did not return an access token.")
        }

        if let expiresIn = json["expires_in"] as? Double {
            json["expiry_date"] = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
        } else if let expiresIn = json["expires_in"] as? Int {
            json["expiry_date"] = Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
        }

        let email = try? await fetchGoogleAccountEmail(accessToken: json["access_token"] as? String)
        if let email, !email.isEmpty {
            json["email"] = email
        }

        let authFileURL = sessionDirectoryURL.appendingPathComponent("oauth_creds.json")
        let fileData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fileData.write(to: authFileURL, options: .atomic)
        return (authFileURL, email)
    }

    private func fetchGoogleAccountEmail(accessToken: String?) async throws -> String? {
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var request = URLRequest(url: Self.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    private nonisolated func respond(on connection: NWConnection, html: String) {
        let data = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """.data(using: .utf8) ?? Data()

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func cleanup(removeArtifacts: Bool) {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        redirectURL = nil
        stateToken = nil
        oauthConfiguration = nil

        if removeArtifacts, let sessionDirectoryURL {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            self.sessionDirectoryURL = nil
            importedAuthFileURL = nil
            accountEmail = nil
        }
    }

    private nonisolated static func resolveOAuthConfiguration() -> OAuthConfiguration? {
        if let environmentConfiguration = oauthConfigurationFromEnvironment(
            clientIDKey: "AIUSAGE_GEMINI_OAUTH_CLIENT_ID",
            clientSecretKey: "AIUSAGE_GEMINI_OAUTH_CLIENT_SECRET"
        ) {
            return environmentConfiguration
        }

        if let bundleDirectory = geminiBundleDirectory() {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: bundleDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "js" {
                guard let content = try? String(contentsOf: file, encoding: .utf8),
                      let clientId = extractConstant("OAUTH_CLIENT_ID", from: content),
                      let clientSecret = extractConstant("OAUTH_CLIENT_SECRET", from: content) else {
                    continue
                }
                return OAuthConfiguration(clientId: clientId, clientSecret: clientSecret)
            }
        }

        return nil
    }

    private nonisolated static func oauthConfigurationFromEnvironment(clientIDKey: String, clientSecretKey: String) -> OAuthConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let clientId = environment[clientIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let clientSecret = environment[clientSecretKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientId.isEmpty,
              !clientSecret.isEmpty else {
            return nil
        }
        return OAuthConfiguration(clientId: clientId, clientSecret: clientSecret)
    }

    private nonisolated static func geminiBundleDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executableCandidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "/usr/bin/gemini",
            "/bin/gemini",
            "\(home)/.local/bin/gemini",
            "\(home)/bin/gemini"
        ]

        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let executableURL = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let parent = executableURL.deletingLastPathComponent().deletingLastPathComponent()
        let directBundle = parent.appendingPathComponent("lib/node_modules/@google/gemini-cli/bundle", isDirectory: true)
        if FileManager.default.fileExists(atPath: directBundle.path) {
            return directBundle
        }

        let commonPaths = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            "/usr/local/lib/node_modules/@google/gemini-cli/bundle"
        ]
        return commonPaths
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private nonisolated static func extractConstant(_ name: String, from content: String) -> String? {
        let patterns = [
            "var\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]+)\"",
            "const\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]+)\""
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  let range = Range(match.range(at: 1), in: content) else {
                continue
            }
            return String(content[range])
        }

        return nil
    }

    private nonisolated static func makeAuthURL(clientId: String, redirectURL: URL, stateToken: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "scope", value: [
                "openid",
                "https://www.googleapis.com/auth/cloud-platform",
                "https://www.googleapis.com/auth/userinfo.email",
                "https://www.googleapis.com/auth/userinfo.profile"
            ].joined(separator: " ")),
            URLQueryItem(name: "state", value: stateToken),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        return components?.url
    }

    private nonisolated static func randomStateToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private nonisolated static func extractRequestURL(from request: String) -> URL? {
        guard let firstLine = request.components(separatedBy: .newlines).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return URL(string: String(parts[1]), relativeTo: URL(string: "http://127.0.0.1"))
    }

    private nonisolated static func isSuccessfulCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.contains("localhost") || host.contains("127.0.0.1") else {
            return false
        }
        return url.path.lowercased().contains("oauth2callback")
    }

    private nonisolated static func successHTML(email: String?) -> String {
        let accountLine = email?.isEmpty == false ? "<p><strong>\(email!)</strong> has been connected.</p>" : ""
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Gemini Connected</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#f6f8fb;color:#111827;">
        <h2 style="margin:0 0 12px;">Gemini account connected</h2>
        \(accountLine)
        <p>You can return to AIUsage now. This tab can be closed.</p>
        </body>
        </html>
        """
    }

    private nonisolated static func failureHTML(message: String) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Gemini Login Failed</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#fff7f7;color:#7f1d1d;">
        <h2 style="margin:0 0 12px;">Gemini login failed</h2>
        <p>\(message)</p>
        <p>You can return to AIUsage and try again.</p>
        </body>
        </html>
        """
    }
}

enum ProviderAuthManager {
    static func plan(for providerId: String) -> ProviderAuthPlan {
        switch providerId {
        case "cursor":
            return ProviderAuthPlan(
                titleEn: "Connect a Cursor account",
                titleZh: "连接 Cursor 账号",
                summaryEn: "Sign in inside the embedded browser and AIUsage will start monitoring that Cursor account immediately.",
                summaryZh: "直接在内置浏览器里登录，AIUsage 会立刻开始监控这个 Cursor 账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: true
            )
        case "amp":
            return ProviderAuthPlan(
                titleEn: "Connect an Amp account",
                titleZh: "连接 Amp 账号",
                summaryEn: "Use the embedded web login and AIUsage will connect that Amp account as its own monitored account.",
                summaryZh: "使用内置网页登录后，AIUsage 会把这个 Amp 账号接成独立的监控账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: true
            )
        case "codex":
            return ProviderAuthPlan(
                titleEn: "Connect a Codex account",
                titleZh: "连接 Codex 账号",
                summaryEn: "AIUsage can start an isolated ChatGPT sign-in just for this Codex account, show the official OpenAI page inside the app, and save the finished login as a separate monitored account automatically.",
                summaryZh: "AIUsage 会为这个 Codex 账号启动一条隔离的 ChatGPT 登录流程，在应用内展示 OpenAI 官方登录页，并在完成后自动保存成独立的监控账号。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "codex-login",
                        titleEn: "Continue with ChatGPT",
                        titleZh: "使用 ChatGPT 继续",
                        subtitleEn: "AIUsage opens the official OpenAI sign-in page in a secure window and connects the account automatically after login.",
                        subtitleZh: "AIUsage 会在安全窗口中打开 OpenAI 官方登录页，并在登录完成后自动接入这个账号。",
                        kind: .runTerminal(command: "codex login")
                    ),
                    ProviderAuthLaunchAction(
                        id: "codex-docs",
                        titleEn: "Open Official Login Guide",
                        titleZh: "打开官方登录说明",
                        subtitleEn: "Read the Codex CLI quickstart if you want the official ChatGPT login notes.",
                        subtitleZh: "如果想看 OpenAI 官方的 ChatGPT 登录说明，可以打开 Codex CLI quickstart。",
                        kind: .openURL(URL(string: "https://github.com/openai/codex#using-codex-with-your-chatgpt-plan")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "copilot":
            return ProviderAuthPlan(
                titleEn: "Connect a GitHub Copilot account",
                titleZh: "连接 GitHub Copilot 账号",
                summaryEn: "Run GitHub's official web login once. AIUsage will detect the resulting GitHub CLI session below and connect it as its own monitored account.",
                summaryZh: "先走一次 GitHub 官方网页登录。AIUsage 会在下方发现这个 GitHub CLI 会话，并把它接成独立监控账号。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "copilot-gh-login",
                        titleEn: "Run GitHub Web Login",
                        titleZh: "运行 GitHub 网页登录",
                        subtitleEn: "Open Terminal and run gh auth login in browser mode.",
                        subtitleZh: "打开终端并以网页模式执行 gh auth login。",
                        kind: .runTerminal(command: "gh auth login -h github.com -p https -w")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "antigravity":
            return ProviderAuthPlan(
                titleEn: "Connect an Antigravity account",
                titleZh: "连接 Antigravity 账号",
                summaryEn: "Open Antigravity and sign in. AIUsage will detect each account session below so you can connect it with one click.",
                summaryZh: "打开 Antigravity 并完成登录。AIUsage 会在下方检测到每个账号会话，你可以一键连接。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "antigravity-app",
                        titleEn: "Open Antigravity",
                        titleZh: "打开 Antigravity",
                        subtitleEn: "Launch the Antigravity app to sign in with another account.",
                        subtitleZh: "打开 Antigravity 应用，用另一个账号完成登录。",
                        kind: .openApp(bundleIdentifier: "com.google.antigravity")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "kiro":
            return ProviderAuthPlan(
                titleEn: "Connect a Kiro account",
                titleZh: "连接 Kiro 账号",
                summaryEn: "Open Kiro and complete sign-in. AIUsage will detect the new Kiro session below and keep it monitoring even after you switch accounts later.",
                summaryZh: "打开 Kiro 并完成登录。AIUsage 会在下方发现新的 Kiro 会话，并在你之后切换账号时继续监控它。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "kiro-app",
                        titleEn: "Open Kiro",
                        titleZh: "打开 Kiro",
                        subtitleEn: "Launch the Kiro desktop app to complete sign-in.",
                        subtitleZh: "打开 Kiro 桌面应用完成登录。",
                        kind: .openApp(bundleIdentifier: "dev.kiro.desktop")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "gemini":
            return ProviderAuthPlan(
                titleEn: "Connect a Gemini CLI account",
                titleZh: "连接 Gemini CLI 账号",
                summaryEn: "AIUsage opens Gemini's official Google sign-in in your browser, receives the OAuth callback itself, and saves that account as a monitored Gemini CLI login automatically.",
                summaryZh: "AIUsage 会直接在浏览器中打开 Gemini 官方 Google 登录页，自己接收 OAuth 回调，并把这个账号自动保存成可监控的 Gemini CLI 登录。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "gemini-login",
                        titleEn: "Continue with Google",
                        titleZh: "使用 Google 继续",
                        subtitleEn: "AIUsage opens the official Google sign-in in your browser and connects the Gemini CLI account automatically after authorization.",
                        subtitleZh: "AIUsage 会在浏览器中打开 Google 官方登录页，并在授权完成后自动接入这个 Gemini CLI 账号。",
                        kind: .runTerminal(command: "gemini")
                    ),
                    ProviderAuthLaunchAction(
                        id: "gemini-docs",
                        titleEn: "Open Official Auth Guide",
                        titleZh: "打开官方认证说明",
                        subtitleEn: "Check Gemini CLI's official authentication guide if you need project or account guidance.",
                        subtitleZh: "如果需要确认项目或账号要求，可以查看 Gemini CLI 官方认证说明。",
                        kind: .openURL(URL(string: "https://geminicli.com/docs/get-started/authentication/")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "droid":
            return ProviderAuthPlan(
                titleEn: "Connect a Droid account",
                titleZh: "连接 Droid 账号",
                summaryEn: "Open Factory if you need to switch accounts first. AIUsage reads Factory's current local login, imports it as its own managed Droid account, and keeps it refreshable after restart.",
                summaryZh: "如果需要切换账号，先打开 Factory 完成登录。AIUsage 会读取当前本地登录态，把它导入成自己管理的 Droid 账号，并在重启后继续正常刷新。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "droid-site",
                        titleEn: "Open Factory",
                        titleZh: "打开 Factory",
                        subtitleEn: "Open the official Droid website to switch or complete the browser login first.",
                        subtitleZh: "打开 Droid 官方网站，先在浏览器里切换或完成登录。",
                        kind: .openURL(URL(string: "https://app.factory.ai")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        default:
            return ProviderAuthPlan(
                titleEn: "Connect account",
                titleZh: "连接账号",
                summaryEn: "Finish the provider's normal sign-in flow first, then AIUsage can connect and monitor that account.",
                summaryZh: "先完成服务商自己的正常登录流程，之后 AIUsage 才能连接并监控这个账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: false
            )
        }
    }

    static func makeCodexCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let json = loadJSONObject(at: path)
        let tokens = json?["tokens"] as? [String: Any]
        let email = jwtEmail(from: stringValue(tokens?["id_token"]))
            ?? jwtEmail(from: stringValue(json?["id_token"]))
            ?? stringValue(json?["email"])
        let fingerprint: String?
        if let json {
            fingerprint = sessionFingerprint(from: json, preferredKeys: ["account_id", "email"])
        } else {
            fingerprint = nil
        }

        return ProviderAuthCandidate(
            id: "codex-oauth:\(path)",
            providerId: "codex",
            sourceIdentifier: "codex-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Codex ChatGPT Login",
            subtitle: "Fresh login",
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func discoverCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let rawCandidates: [ProviderAuthCandidate]

        switch providerId {
        case "codex":
            rawCandidates = codexCandidates()
        case "cursor":
            rawCandidates = cursorCandidates()
        case "amp":
            rawCandidates = ampCandidates()
        case "copilot":
            rawCandidates = copilotCandidates()
        case "antigravity":
            rawCandidates = antigravityCandidates()
        case "kiro":
            rawCandidates = kiroCandidates()
        case "gemini":
            rawCandidates = geminiCandidates()
        case "droid":
            rawCandidates = droidCandidates()
        default:
            rawCandidates = []
        }

        return rawCandidates.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func unmanagedCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let monitored = monitoredSessions(for: providerId)
        return discoverCandidates(for: providerId).filter { !isCandidateManaged($0, monitored: monitored) }
    }

    static func preferredQuickConnectCandidate(for providerId: String) -> ProviderAuthCandidate? {
        let monitored = monitoredSessions(for: providerId)
        let prioritized: [ProviderAuthCandidate]

        switch providerId {
        case "droid":
            prioritized = droidCandidates()
        default:
            prioritized = discoverCandidates(for: providerId)
        }

        return prioritized.first { !isCandidateManaged($0, monitored: monitored) }
    }

    static func monitoredSessions(for providerId: String) -> ProviderMonitoredSessionIndex {
        let credentials = AccountCredentialStore.shared.loadCredentials(for: providerId)
        return ProviderMonitoredSessionIndex(
            sourceIdentifiers: Set(credentials.compactMap { credential in
                guard sourceIdentifierIsStableIdentity(for: credential) else { return nil }
                return credential.metadata["sourceIdentifier"]
                    ?? credential.metadata["sourcePath"]
                    ?? authFileSourceIdentifier(for: credential.credential, authMethod: credential.authMethod)
            }),
            sessionFingerprints: Set(credentials.compactMap { credential in
                normalizedHandle(credential.metadata["sessionFingerprint"])
            }),
            accountHandles: Set(credentials.compactMap { credential in
                normalizedHandle(
                    credential.metadata["accountHandle"]
                        ?? credential.metadata["accountEmail"]
                        ?? credential.accountLabel
                )
            })
        )
    }

    static func launch(_ action: ProviderAuthLaunchAction) throws {
        switch action.kind {
        case .openApp(let bundleIdentifier):
            try runOpen(arguments: ["-b", bundleIdentifier])
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .revealPath(let path):
            let expanded = expand(path)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
        case .runTerminal(let command):
            try launchTerminal(command: command)
        }
    }

    static func authenticateCandidate(_ candidate: ProviderAuthCandidate) async throws -> (AccountCredential, ProviderUsage) {
        var copiedPath: String?
        do {
            let credentialValue: String
            if candidate.authMethod == .authFile, candidate.shouldCopyFile, let sourcePath = candidate.sourcePath {
                copiedPath = try copyImportedAuthFile(
                    providerId: candidate.providerId,
                    sourcePath: sourcePath,
                    suggestedName: candidate.title
                )
                credentialValue = copiedPath ?? sourcePath
            } else {
                credentialValue = candidate.credentialValue
            }

            let storedSourcePath: String
            if (candidate.providerId == "codex" || candidate.providerId == "gemini" || candidate.providerId == "kiro"), let copiedPath {
                // Codex, Gemini, and Kiro imports may originate from singleton session
                // files (for example ~/.codex/auth.json, ~/.gemini/oauth_creds.json, or
                // Kiro's IDE cache). Once imported, the managed copy must remain the
                // source of truth so later logins do not overwrite this saved account.
                storedSourcePath = copiedPath
            } else {
                storedSourcePath = candidate.sourcePath ?? ""
            }

            let credential = AccountCredential(
                providerId: candidate.providerId,
                accountLabel: candidate.title.nilIfBlank,
                authMethod: candidate.authMethod,
                credential: credentialValue,
                metadata: [
                    "sourceIdentifier": candidate.sourceIdentifier,
                    "sourcePath": storedSourcePath,
                    "importedAt": ISO8601DateFormatter().string(from: Date()),
                    "sessionFingerprint": candidate.sessionFingerprint ?? "",
                    "identityScope": candidate.identityScope.rawValue
                ]
            )

            let usage = try await validate(credential: credential)
            return (credential, usage)
        } catch {
            if let copiedPath {
                try? FileManager.default.removeItem(atPath: copiedPath)
            }
            throw error
        }
    }

    static func authenticateManualCredential(
        providerId: String,
        authMethod: AuthMethod,
        value: String,
        suggestedLabel: String? = nil
    ) async throws -> (AccountCredential, ProviderUsage) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError("missing_credential", "Credential value is empty.")
        }

        let credential = AccountCredential(
            providerId: providerId,
            accountLabel: suggestedLabel?.nilIfBlank,
            authMethod: authMethod,
            credential: trimmed,
            metadata: [
                "sourceIdentifier": "manual:\(authMethod.rawValue):\(UUID().uuidString)",
                "importedAt": ISO8601DateFormatter().string(from: Date()),
                "identityScope": ProviderAuthCandidate.IdentityScope.sharedSource.rawValue
            ]
        )
        let usage = try await validate(credential: credential)
        return (credential, usage)
    }

    // MARK: - Candidate Discovery

    fileprivate static func codexCandidates() -> [ProviderAuthCandidate] {
        var candidates = authFileCandidates(
            providerId: "codex",
            directory: "~/.cli-proxy-api",
            prefix: "codex-"
        ) { url, json in
            let email = stringValue(json["email"])
                ?? jwtEmail(from: stringValue(json["id_token"]))
            return ProviderAuthCandidate(
                id: "codex:\(canonicalPath(url.path))",
                providerId: "codex",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["account_id", "email"]),
                title: email ?? readableFilename(url),
                subtitle: "CLI Proxy API",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .accountScoped
            )
        }

        let defaultURL = URL(fileURLWithPath: expand("~/.codex/auth.json"))
        if FileManager.default.fileExists(atPath: defaultURL.path),
           let json = loadJSONObject(at: defaultURL.path) {
            let email = jwtEmail(from: stringValue((json["tokens"] as? [String: Any])?["id_token"]))
                ?? stringValue(json["email"])
            candidates.append(
                ProviderAuthCandidate(
                    id: "codex:\(canonicalPath(defaultURL.path))",
                    providerId: "codex",
                    sourceIdentifier: "file:\(canonicalPath(defaultURL.path))",
                    sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["account_id", "email"]),
                    title: email ?? "Current ChatGPT login",
                    subtitle: "Current ChatGPT login",
                    detail: compactDetail(parts: [displayPath(defaultURL.path), formattedDate(modificationDate(for: defaultURL))]),
                    modifiedAt: modificationDate(for: defaultURL),
                    authMethod: .authFile,
                    credentialValue: defaultURL.path,
                    sourcePath: defaultURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    private static func copilotCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        if let session = currentGitHubCLISession() {
            candidates.append(
                ProviderAuthCandidate(
                    id: "copilot:\(session.sourceIdentifier)",
                    providerId: "copilot",
                    sourceIdentifier: session.sourceIdentifier,
                    sessionFingerprint: session.sessionFingerprint,
                    title: session.label,
                    subtitle: "GitHub CLI",
                    detail: session.detail,
                    modifiedAt: nil,
                    authMethod: .token,
                    credentialValue: session.token,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .accountScoped
                )
            )
        }

        candidates.append(contentsOf: authFileCandidates(
            providerId: "copilot",
            directory: "~/.cli-proxy-api",
            prefix: "github-copilot-"
        ) { url, json in
            guard let token = stringValue(json["access_token"]) else { return nil }
            let username = stringValue(json["username"]) ?? readableFilename(url)
            return ProviderAuthCandidate(
                id: "copilot:\(canonicalPath(url.path))",
                providerId: "copilot",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["username", "login"]),
                title: username,
                subtitle: "Saved token file",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .token,
                credentialValue: token,
                sourcePath: url.path,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        })

        return deduplicated(candidates)
    }

    private static func antigravityCandidates() -> [ProviderAuthCandidate] {
        authFileCandidates(providerId: "antigravity", directory: "~/.cli-proxy-api", prefix: "antigravity-") { url, json in
            let email = stringValue(json["email"]) ?? readableFilename(url)
            return ProviderAuthCandidate(
                id: "antigravity:\(canonicalPath(url.path))",
                providerId: "antigravity",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email", "account_id"]),
                title: email,
                subtitle: "CLI Proxy API",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .accountScoped
            )
        }
    }

    private static func kiroCandidates() -> [ProviderAuthCandidate] {
        var candidates = authFileCandidates(providerId: "kiro", directory: "~/.cli-proxy-api", prefix: "kiro-") { url, json in
            let email = stringValue(json["email"])
            let provider = stringValue(json["provider"])
            let title = email ?? (provider.map { "Kiro (\($0))" }) ?? readableFilename(url)
            return ProviderAuthCandidate(
                id: "kiro:\(canonicalPath(url.path))",
                providerId: "kiro",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email", "userId", "accountEmail"]),
                title: title,
                subtitle: "CLI Proxy API",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .accountScoped
            )
        }

        let ideURL = URL(fileURLWithPath: expand("~/.aws/sso/cache/kiro-auth-token.json"))
        if FileManager.default.fileExists(atPath: ideURL.path),
           let json = loadJSONObject(at: ideURL.path) {
            let provider = stringValue(json["provider"]) ?? "IDE"
            candidates.append(
                ProviderAuthCandidate(
                    id: "kiro:\(canonicalPath(ideURL.path))",
                    providerId: "kiro",
                    sourceIdentifier: "file:\(canonicalPath(ideURL.path))",
                    sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email", "userId", "accountEmail"]),
                    title: "Kiro (\(provider))",
                    subtitle: "IDE session cache",
                    detail: compactDetail(parts: [displayPath(ideURL.path), formattedDate(modificationDate(for: ideURL))]),
                    modifiedAt: modificationDate(for: ideURL),
                    authMethod: .authFile,
                    credentialValue: ideURL.path,
                    sourcePath: ideURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    private static func geminiCandidates() -> [ProviderAuthCandidate] {
        let oauthURL = URL(fileURLWithPath: expand("~/.gemini/oauth_creds.json"))
        guard FileManager.default.fileExists(atPath: oauthURL.path),
              let json = loadJSONObject(at: oauthURL.path) else {
            return []
        }

        let email = stringValue(json["email"])
            ?? jwtEmail(from: stringValue(json["id_token"]))
            ?? "Current Gemini CLI session"
        return [
            ProviderAuthCandidate(
                id: "gemini:\(canonicalPath(oauthURL.path))",
                providerId: "gemini",
                sourceIdentifier: "file:\(canonicalPath(oauthURL.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email"]),
                title: email,
                subtitle: "Current Gemini CLI login",
                detail: compactDetail(parts: [displayPath(oauthURL.path), formattedDate(modificationDate(for: oauthURL))]),
                modifiedAt: modificationDate(for: oauthURL),
                authMethod: .authFile,
                credentialValue: oauthURL.path,
                sourcePath: oauthURL.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        ]
    }

    private static func droidCandidates() -> [ProviderAuthCandidate] {
        let candidatePaths = [
            "~/.factory/auth.v2.file",
            "~/.factory/auth.v2.keyring",
            "~/.factory/auth.encrypted",
            "~/.config/factory/auth.json",
            "~/.factory/auth.json",
            "~/.config/droid/auth.json"
        ]

        var candidates = candidatePaths.compactMap { rawPath -> ProviderAuthCandidate? in
            let path = expand(rawPath)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let snapshot = DroidProvider.loadStoredSessionSnapshot(at: url.path) else {
                return nil
            }

            let accessToken = snapshot.accessToken
            let email = jwtEmail(from: accessToken)
            let subject = jwtClaim("sub", from: accessToken)
            let title = email ?? subject ?? "Current Droid login"
            let fingerprint = normalizedHandle(email ?? subject)
                ?? sessionFingerprint(
                    from: [
                        "access_token": accessToken as Any,
                        "refresh_token": snapshot.refreshToken as Any
                    ],
                    preferredKeys: ["access_token", "refresh_token"]
                )

            return ProviderAuthCandidate(
                id: "droid:\(canonicalPath(url.path))",
                providerId: "droid",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: fingerprint,
                title: title,
                subtitle: "Local Factory login",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        }

        candidates.append(contentsOf: DroidProvider.discoverBrowserSessions().map { session in
            let profileLabel = "\(session.browserName) \(session.profileName)"
            let sourceIdentifier = "browser-profile:droid:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
            return ProviderAuthCandidate(
                id: "droid:\(sourceIdentifier)",
                providerId: "droid",
                sourceIdentifier: sourceIdentifier,
                sessionFingerprint: tokenFingerprint(session.cookieHeader),
                title: session.accountHint ?? profileLabel,
                subtitle: "Browser session",
                detail: compactDetail(parts: [profileLabel, "factory.ai"]),
                modifiedAt: nil,
                authMethod: .cookie,
                credentialValue: session.cookieHeader,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .sharedSource
            )
        })

        return deduplicated(candidates)
    }

    private static func ampCandidates() -> [ProviderAuthCandidate] {
        deduplicated(
            AmpProvider.discoverBrowserSessions().map { session in
                let profileLabel = "\(session.browserName) \(session.profileName)"
                let sourceIdentifier = "browser-profile:amp:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
                return ProviderAuthCandidate(
                    id: "amp:\(sourceIdentifier)",
                    providerId: "amp",
                    sourceIdentifier: sourceIdentifier,
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.accountHint ?? profileLabel,
                    subtitle: "Browser session",
                    detail: compactDetail(parts: [profileLabel, "ampcode.com"]),
                    modifiedAt: nil,
                    authMethod: .cookie,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource
                )
            }
        )
    }

    private static func cursorCandidates() -> [ProviderAuthCandidate] {
        deduplicated(
            CursorProvider.discoverBrowserSessions().map { session in
                let profileLabel = "\(session.browserName) \(session.profileName)"
                let sourceIdentifier = "browser-profile:cursor:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
                return ProviderAuthCandidate(
                    id: "cursor:\(sourceIdentifier)",
                    providerId: "cursor",
                    sourceIdentifier: sourceIdentifier,
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.accountHint ?? profileLabel,
                    subtitle: "Browser session",
                    detail: compactDetail(parts: [profileLabel, "cursor.com"]),
                    modifiedAt: nil,
                    authMethod: .cookie,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource
                )
            }
        )
    }

    private static func authFileCandidates(
        providerId: String,
        directory: String,
        prefix: String,
        builder: (URL, [String: Any]) -> ProviderAuthCandidate?
    ) -> [ProviderAuthCandidate] {
        let directoryURL = URL(fileURLWithPath: expand(directory), isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { url in
                guard let json = loadJSONObject(at: url.path) else { return nil }
                return builder(url, json)
            }
    }

    // MARK: - Validation

    private static func validate(credential: AccountCredential) async throws -> ProviderUsage {
        guard let provider = ProviderRegistry.provider(for: credential.providerId) as? any CredentialAcceptingProvider else {
            throw ProviderError("unsupported_provider", "\(credential.providerId) does not accept imported credentials.")
        }
        return try await provider.fetchUsage(with: credential)
    }

    // MARK: - Import Persistence

    private static func copyImportedAuthFile(
        providerId: String,
        sourcePath: String,
        suggestedName: String
    ) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let directory = try managedImportDirectory(for: providerId)
        let stem = sanitizedFilenameStem(suggestedName)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "\(stem)-\(formatter.string(from: Date())).json"
        let destinationURL = directory.appendingPathComponent(filename)

        let data: Data
        if providerId == "droid",
           let normalizedData = DroidProvider.managedSessionData(from: sourcePath) {
            data = normalizedData
        } else {
            data = try Data(contentsOf: sourceURL)
        }
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL.path
    }

    private static func managedImportDirectory(for providerId: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("AuthImports", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Launch Helpers

    private static func runOpen(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderError("launch_failed", "Could not launch the requested sign-in flow.")
        }
    }

    private static func launchTerminal(command: String) throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let scriptURL = tempDirectory.appendingPathComponent("aiusage-auth-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh
        \(command)
        printf "\\n\\nPress any key to close..."
        read -k 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        try runOpen(arguments: ["-a", "Terminal", scriptURL.path])
    }

    // MARK: - Parsing Helpers

    private struct GitHubCLISession {
        let label: String
        let token: String
        let detail: String
        let sourceIdentifier: String
        let sessionFingerprint: String
    }

    private static func currentGitHubCLISession() -> GitHubCLISession? {
        let token = runCommand(path: "/opt/homebrew/bin/gh", arguments: ["auth", "token"])
            ?? runCommand(path: "/usr/local/bin/gh", arguments: ["auth", "token"])
            ?? runCommand(path: "/usr/bin/gh", arguments: ["auth", "token"])
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        let hostsPath = expand("~/.config/gh/hosts.yml")
        let hostsContent = try? String(contentsOfFile: hostsPath, encoding: .utf8)
        let username = hostsContent?
            .components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("user:") })?
            .components(separatedBy: ":")
            .dropFirst()
            .joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = username?.nilIfBlank ?? "Current GitHub CLI session"
        return GitHubCLISession(
            label: label,
            token: token,
            detail: displayPath(hostsPath),
            sourceIdentifier: "gh-cli:\(label.lowercased())",
            sessionFingerprint: tokenFingerprint(token)
        )
    }

    private static func loadJSONObject(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtEmail(from token: String?) -> String? {
        jwtClaim("email", from: token)
    }

    private static func jwtClaim(_ claim: String, from token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = stringValue(json[claim]) {
            return value
        }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any] {
            return stringValue(profile[claim])
        }
        return nil
    }

    private static func sessionFingerprint(from json: [String: Any], preferredKeys: [String] = []) -> String? {
        for key in preferredKeys {
            if let value = stringValue(json[key]) {
                return normalizedHandle(value)
            }
        }

        if let email = jwtEmail(from: stringValue(json["id_token"])) {
            return normalizedHandle(email)
        }

        if let subject = jwtClaim("sub", from: stringValue(json["id_token"])) {
            return normalizedHandle(subject)
        }

        if let tokens = json["tokens"] as? [String: Any] {
            if let email = jwtEmail(from: stringValue(tokens["id_token"])) {
                return normalizedHandle(email)
            }

            if let subject = jwtClaim("sub", from: stringValue(tokens["id_token"])) {
                return normalizedHandle(subject)
            }

            for key in ["refresh_token", "access_token", "id_token"] {
                if let token = stringValue(tokens[key]) {
                    return tokenFingerprint(token)
                }
            }
        }

        for key in ["account_id", "email", "username", "login", "userId", "accountEmail", "refresh_token", "access_token", "id_token"] {
            if let value = stringValue(json[key]) {
                return key.contains("token") ? tokenFingerprint(value) : normalizedHandle(value)
            }
        }

        return nil
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func readableFilename(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func compactDetail(parts: [String?]) -> String {
        parts.compactMap { $0?.nilIfBlank }.joined(separator: " · ")
    }

    private static func normalizedHandle(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    private static func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func authFileSourceIdentifier(for value: String, authMethod: AuthMethod) -> String? {
        guard authMethod == .authFile else { return nil }
        return "file:\(canonicalPath(value))"
    }

    private static func sourceIdentifierIsStableIdentity(for credential: AccountCredential) -> Bool {
        credential.metadata["identityScope"] == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue
    }

    private static func sourceIdentifierIsStableIdentity(for candidate: ProviderAuthCandidate) -> Bool {
        candidate.identityScope == .accountScoped
    }

    private static func sanitizedFilenameStem(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let joined = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.nilIfBlank ?? "account"
    }

    private static func tokenFingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func deduplicated(_ candidates: [ProviderAuthCandidate]) -> [ProviderAuthCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.sessionFingerprint.map { "fp:\($0)" } ?? "source:\(candidate.sourceIdentifier)"
            return seen.insert(key).inserted
        }
    }

    private static func isCandidateManaged(_ candidate: ProviderAuthCandidate, monitored: ProviderMonitoredSessionIndex) -> Bool {
        if sourceIdentifierIsStableIdentity(for: candidate),
           monitored.sourceIdentifiers.contains(candidate.sourceIdentifier) {
            return true
        }

        if let fingerprint = candidate.sessionFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           monitored.sessionFingerprints.contains(fingerprint) {
            return true
        }

        let normalizedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitored.accountHandles.contains(normalizedTitle)
    }

    private static func runCommand(path: String, arguments: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
