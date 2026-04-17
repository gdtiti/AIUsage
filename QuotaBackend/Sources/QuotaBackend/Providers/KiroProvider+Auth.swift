import Foundation

// MARK: - Auth Context

extension KiroProvider {
    /// Resolve ALL auth contexts for multi-account fetching
    func resolveAllAuthContexts() throws -> [AuthContext] {
        let env = ProcessInfo.processInfo.environment

        if let explicitFile = env["KIRO_AUTH_FILE"], !explicitFile.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: explicitFile).expandingTildeInPath)
            return [try loadAuthContext(url: url, fileCount: 1, sourceDirectory: url.deletingLastPathComponent().path, sourceType: sourceType(for: url))]
        }

        let authDirectory = env["KIRO_AUTH_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? "\(homeDirectory)/.cli-proxy-api"
        let directoryURL = URL(fileURLWithPath: authDirectory, isDirectory: true)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let matches = files.filter {
            $0.lastPathComponent.hasPrefix("kiro-") && $0.pathExtension == "json"
        }

        let ideAuthURL = URL(fileURLWithPath: "\(homeDirectory)/.aws/sso/cache/kiro-auth-token.json")

        var candidates: [URL] = matches
        if FileManager.default.fileExists(atPath: ideAuthURL.path) {
            candidates.append(ideAuthURL)
        }

        guard !candidates.isEmpty else {
            throw ProviderError("not_logged_in", "No Kiro auth file found. Expected ~/.cli-proxy-api/kiro-*.json or ~/.aws/sso/cache/kiro-auth-token.json.")
        }

        let contexts = candidates
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
            .compactMap { url in
                try? loadAuthContext(
                    url: url,
                    fileCount: candidates.count,
                    sourceDirectory: url.deletingLastPathComponent().path,
                    sourceType: sourceType(for: url)
                )
            }
        return enrichEmailHints(in: deduplicateByProfile(contexts))
    }

    /// Legacy single-file resolution (picks latest modified)
    func resolveAuthContext() throws -> AuthContext {
        let contexts = try resolveAllAuthContexts()
        guard let first = contexts.first else {
            throw ProviderError("not_logged_in", "No valid Kiro auth files found.")
        }
        return first
    }

    /// Keep only the newest auth context per profileArn.
    /// Contexts without profileArn are always kept (cannot determine identity).
    func deduplicateByProfile(_ contexts: [AuthContext]) -> [AuthContext] {
        var seenProfiles = Set<String>()
        return contexts.filter { ctx in
            guard let arn = ctx.tokenData.profileArn?.lowercased(), !arn.isEmpty else { return true }
            return seenProfiles.insert(arn).inserted
        }
    }

    func sourceType(for url: URL) -> String {
        url.lastPathComponent == "kiro-auth-token.json" ? "kiro-ide-auth-file" : "cli-proxy-auth-file"
    }

    func loadAuthContext(url: URL, fileCount: Int, sourceDirectory: String, sourceType: String) throws -> AuthContext {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError("not_logged_in", "Kiro auth file not found at \(url.path).")
        }

        let data = try Data(contentsOf: url)
        var tokenData = try parseTokenData(from: data, url: url)

        if tokenData.authMethod == "idc", (tokenData.clientId == nil || tokenData.clientSecret == nil) {
            let registration = loadKiroDeviceRegistration()
            if tokenData.clientId == nil { tokenData.clientId = registration.clientId }
            if tokenData.clientSecret == nil { tokenData.clientSecret = registration.clientSecret }
        }

        if tokenData.accessToken.isEmpty {
            throw ProviderError("missing_tokens", "Kiro auth file exists but has no access token.")
        }

        return AuthContext(
            url: url,
            tokenData: tokenData,
            rawData: data,
            fileCount: fileCount,
            sourceDirectory: sourceDirectory,
            sourceType: sourceType
        )
    }

    func resolveCredentialAuthContext(_ credential: AccountCredential) throws -> AuthContext {
        let path = NSString(string: credential.credential).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return try loadAuthContext(
            url: url,
            fileCount: 1,
            sourceDirectory: url.deletingLastPathComponent().path,
            sourceType: sourceType(for: url)
        )
    }

    func parseTokenData(from data: Data, url: URL) throws -> KiroTokenData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Kiro auth file contained invalid JSON.")
        }

        let accessToken = stringValue(json["access_token"]) ?? stringValue(json["accessToken"]) ?? ""
        let refreshToken = stringValue(json["refresh_token"]) ?? stringValue(json["refreshToken"])
        let profileArn = stringValue(json["profile_arn"]) ?? stringValue(json["profileArn"])

        var expiresAt = stringValue(json["expires_at"]) ?? stringValue(json["expiresAt"]) ?? stringValue(json["expiry"])
        if expiresAt == nil, let numericExpiry = doubleValue(json["expires_at"] ?? json["expiresAt"] ?? json["expiry"]) {
            let epoch = numericExpiry > 1e12 ? numericExpiry / 1000 : numericExpiry
            expiresAt = iso8601String(Date(timeIntervalSince1970: epoch))
        }

        let authProvider = stringValue(json["provider"])
        let authMethod = (stringValue(json["auth_method"]) ?? stringValue(json["authMethod"]) ?? defaultAuthMethod(provider: authProvider)).lowercased()
        let region = stringValue(json["region"]) ?? extractRegionFromProfileArn(profileArn) ?? Self.defaultRegion
        let email = firstNonEmptyString(
            json["email"],
            json["accountEmail"],
            json["userEmail"],
            json["loginHint"]
        )

        return KiroTokenData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            clientId: stringValue(json["client_id"]) ?? stringValue(json["clientId"]),
            clientSecret: stringValue(json["client_secret"]) ?? stringValue(json["clientSecret"]),
            authMethod: authMethod,
            region: region,
            profileArn: profileArn,
            authProvider: authProvider,
            email: email
        )
    }

    func enrichEmailHints(in contexts: [AuthContext]) -> [AuthContext] {
        let hintedEmailsByProfile: [String: String] = Dictionary(
            uniqueKeysWithValues: contexts.compactMap { context -> (String, String)? in
                guard let profileArn = context.tokenData.profileArn,
                      let email = context.tokenData.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !email.isEmpty else {
                    return nil
                }
                return (profileArn, email)
            }
        )

        return contexts.map { context in
            let currentEmail = context.tokenData.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentEmail == nil || currentEmail?.isEmpty == true,
                  let profileArn = context.tokenData.profileArn,
                  let hintedEmail = hintedEmailsByProfile[profileArn] else {
                return context
            }

            var tokenData = context.tokenData
            tokenData.email = hintedEmail
            return AuthContext(
                url: context.url,
                tokenData: tokenData,
                rawData: context.rawData,
                fileCount: context.fileCount,
                sourceDirectory: context.sourceDirectory,
                sourceType: context.sourceType
            )
        }
    }

    func defaultAuthMethod(provider: String?) -> String {
        provider?.lowercased() == "google" ? "social" : "idc"
    }

    func fallbackAccountName(from filename: String, authProvider: String?) -> String? {
        if filename == "kiro-auth-token.json" {
            return authProvider.map { "Kiro (\($0))" } ?? "Kiro IDE"
        }

        guard filename.hasPrefix("kiro-"), filename.hasSuffix(".json") else {
            return authProvider.map { "Kiro (\($0))" }
        }

        let value = filename
            .replacingOccurrences(of: "kiro-", with: "")
            .replacingOccurrences(of: ".json", with: "")
        return value.isEmpty ? authProvider.map { "Kiro (\($0))" } : value
    }

    func loadKiroDeviceRegistration() -> (clientId: String?, clientSecret: String?) {
        let cachePath = "\(homeDirectory)/.aws/sso/cache"
        let authTokenPath = "\(cachePath)/kiro-auth-token.json"

        var clientIdHash: String?
        if let data = FileManager.default.contents(atPath: authTokenPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            clientIdHash = json["clientIdHash"] as? String
        }

        if let hash = clientIdHash {
            let registrationPath = "\(cachePath)/\(hash).json"
            if let data = FileManager.default.contents(atPath: registrationPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let clientId = json["clientId"] as? String,
               let clientSecret = json["clientSecret"] as? String {
                return (clientId, clientSecret)
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(atPath: cachePath) {
            for file in files where file.hasSuffix(".json") && file != "kiro-auth-token.json" {
                let filePath = "\(cachePath)/\(file)"
                if let data = FileManager.default.contents(atPath: filePath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let clientId = json["clientId"] as? String,
                   let clientSecret = json["clientSecret"] as? String {
                    return (clientId, clientSecret)
                }
            }
        }

        return (nil, nil)
    }

    func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Token Refresh

    func refreshToken(tokenData: KiroTokenData,
                      authContext: AuthContext,
                      originalData: Data) async throws -> RefreshedToken {
        guard let refreshToken = tokenData.refreshToken, !refreshToken.isEmpty else {
            throw ProviderError("missing_refresh_token", "Kiro auth is missing a refresh token.")
        }

        let refreshed: RefreshedToken
        if tokenData.authMethod == "social" {
            refreshed = try await refreshSocialToken(refreshToken: refreshToken, region: tokenData.region)
        } else {
            refreshed = try await refreshIdCToken(tokenData: tokenData, refreshToken: refreshToken)
        }

        persistRefreshedToken(at: authContext.url, originalData: originalData, refreshed: refreshed, sourceType: authContext.sourceType)
        if authContext.sourceType != "kiro-ide-auth-file" {
            syncToKiroIDEAuthFile(refreshed: refreshed, authContext: authContext)
        }

        return refreshed
    }

    func refreshSocialToken(refreshToken: String, region: String) async throws -> RefreshedToken {
        guard let url = URL(string: socialTokenEndpoint(region: region)) else {
            throw ProviderError("invalid_url", "Failed to build the Kiro social token endpoint.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError("refresh_failed", "Kiro social token refresh failed.")
        }

        let payload = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
        return RefreshedToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    func refreshIdCToken(tokenData: KiroTokenData, refreshToken: String) async throws -> RefreshedToken {
        guard let clientId = tokenData.clientId, !clientId.isEmpty,
              let clientSecret = tokenData.clientSecret, !clientSecret.isEmpty,
              let url = URL(string: idcTokenEndpoint(region: tokenData.region)) else {
            throw ProviderError("missing_credentials", "Kiro IdC auth is missing client credentials.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oidc.\(tokenData.region).amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("aws-sdk-js/3.980.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.980.0 m/E KiroIDE", forHTTPHeaderField: "x-amz-user-agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("node", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError("refresh_failed", "Kiro IdC token refresh failed.")
        }

        let payload = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
        return RefreshedToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    func persistRefreshedToken(at url: URL, originalData: Data, refreshed: RefreshedToken, sourceType: String) {
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        let isCamelCase = sourceType == "kiro-ide-auth-file" || json["accessToken"] != nil

        if isCamelCase {
            json["accessToken"] = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken { json["refreshToken"] = refreshToken }
            json["expiresAt"] = iso8601String(refreshed.expiryDate)
        } else {
            json["access_token"] = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken { json["refresh_token"] = refreshToken }
            json["expires_at"] = iso8601String(refreshed.expiryDate)
            json["last_refresh"] = iso8601String(Date())
        }

        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? updated.write(to: url, options: .atomic)
    }

    func syncToKiroIDEAuthFile(refreshed: RefreshedToken, authContext: AuthContext) {
        let ideAuthURL = URL(fileURLWithPath: "\(homeDirectory)/.aws/sso/cache/kiro-auth-token.json")
        guard FileManager.default.fileExists(atPath: ideAuthURL.path),
              let data = FileManager.default.contents(atPath: ideAuthURL.path),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let ideProfileArn = json["profileArn"] as? String ?? json["profile_arn"] as? String
        let ctxProfileArn = authContext.tokenData.profileArn
        if ideProfileArn != ctxProfileArn { return }

        json["accessToken"] = refreshed.accessToken
        if let refreshToken = refreshed.refreshToken {
            json["refreshToken"] = refreshToken
        }
        json["expiresAt"] = iso8601String(refreshed.expiryDate)

        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? updated.write(to: ideAuthURL, options: .atomic)
    }
}
