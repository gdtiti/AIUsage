import Foundation
import CommonCrypto

// MARK: - Droid Provider — Static Helpers

extension DroidProvider {
    static func extractDroidCookieHeader(dbPath: String, keychainService: String) -> String? {
        let tempPath = NSTemporaryDirectory() + "droid_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 10000...99999)).db"
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
        }
        do { try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath) } catch { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: dbPath + "-wal") {
            try? fm.copyItem(atPath: dbPath + "-wal", toPath: tempPath + "-wal")
        }
        if fm.fileExists(atPath: dbPath + "-shm") {
            try? fm.copyItem(atPath: dbPath + "-shm", toPath: tempPath + "-shm")
        }

        let query = """
        SELECT name, expires_utc, hex(encrypted_value), value
        FROM cookies
        WHERE name IN (\(Self.sessionCookieNames.map { "'\($0)'" }.joined(separator: ",")))
          AND (host_key = 'factory.ai' OR host_key = '.factory.ai' OR host_key LIKE '%.factory.ai')
        ORDER BY expires_utc DESC
        LIMIT 40;
        """

        guard let rows = querySQLite(db: tempPath, sql: query) else { return nil }
        guard !rows.isEmpty else { return nil }

        let aesKey = chromiumAESKey(keychainService: keychainService)
        var cookiesByName: [String: String] = [:]

        for row in rows {
            guard row.count >= 4 else { continue }
            let name = row[0]
            guard Self.sessionCookieNames.contains(name), cookiesByName[name] == nil else { continue }

            let hexBlob = row[2]
            let plainValue = row[3]

            if let plain = plainValue.nilIfBlank, isCookieSafeASCII(plain) {
                cookiesByName[name] = plain
                continue
            }

            if let aesKey, let decrypted = CursorProvider.decryptChromiumCookie(blob: hexBlob, key: aesKey) {
                cookiesByName[name] = decrypted
            }
        }

        guard !cookiesByName.isEmpty else { return nil }

        let orderedPairs = cookiesByName
            .sorted { lhs, rhs in
                let leftPriority = cookieNamePriority(lhs.key)
                let rightPriority = cookieNamePriority(rhs.key)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { "\($0.key)=\($0.value)" }

        return orderedPairs.joined(separator: "; ")
    }

    static func cookieNamePriority(_ name: String) -> Int {
        switch name {
        case "access-token": return 0
        case "wos-session": return 1
        case "__Secure-next-auth.session-token": return 2
        case "next-auth.session-token": return 3
        case "__Secure-authjs.session-token": return 4
        case "authjs.session-token": return 5
        case "__Host-authjs.csrf-token": return 6
        case "session": return 7
        default: return 100
        }
    }

    static func querySQLite(db: String, sql: String) -> [[String]]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-separator", "\t", db, sql]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    static func chromiumAESKey(keychainService: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }

        let password = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !password.isEmpty, let passwordData = password.data(using: .utf8) else { return nil }

        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let status = derivedKey.withUnsafeMutableBytes { derivedPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress, passwordData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedPtr.baseAddress, 16
                    )
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    static func normalizeCookieHeader(_ rawHeader: String) -> String {
        let pairs = cookiePairs(from: rawHeader)
        guard !pairs.isEmpty else { return "" }

        var byName: [String: String] = [:]
        for pair in pairs where byName[pair.name] == nil {
            byName[pair.name] = pair.value
        }

        return byName
            .sorted { lhs, rhs in
                let leftPriority = cookieNamePriority(lhs.key)
                let rightPriority = cookieNamePriority(rhs.key)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func filteredCookieHeader(_ rawHeader: String, removing names: Set<String>) -> String {
        cookiePairs(from: rawHeader)
            .filter { !names.contains($0.name) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func filteredCookieHeader(_ rawHeader: String, keeping names: Set<String>) -> String {
        cookiePairs(from: rawHeader)
            .filter { names.contains($0.name) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func cookiePairs(from header: String) -> [(name: String, value: String)] {
        header
            .split(separator: ";")
            .compactMap { segment in
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.firstIndex(of: "=") else { return nil }
                let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { return nil }
                return (name, value)
            }
    }

    static func bearerToken(fromCookieHeader cookieHeader: String?) -> String? {
        guard let cookieHeader else { return nil }
        let pairs = cookiePairs(from: cookieHeader)

        for preferredName in ["access-token", "wos-session", "__Secure-next-auth.session-token", "next-auth.session-token", "__Secure-authjs.session-token", "authjs.session-token", "session"] {
            guard let pair = pairs.first(where: { $0.name == preferredName }) else {
                continue
            }
            let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                continue
            }
            if token.contains(".") || preferredName == "access-token" {
                return token
            }
        }

        return nil
    }

    static func jwtEmail(from token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    static func base64URLSafeToStandard(_ input: String) -> String {
        var result = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = result.count % 4
        if remainder > 0 { result += String(repeating: "=", count: 4 - remainder) }
        return result
    }

    static func isCookieSafeASCII(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        for scalar in string.unicodeScalars {
            let value = scalar.value
            let allowed = value == 0x21
                || (value >= 0x23 && value <= 0x2b)
                || (value >= 0x2d && value <= 0x3a)
                || (value >= 0x3c && value <= 0x5b)
                || (value >= 0x5d && value <= 0x7e)
            if !allowed { return false }
        }
        return true
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        switch self {
        case .some(let value):
            return value.nilIfBlank
        case .none:
            return nil
        }
    }
}
