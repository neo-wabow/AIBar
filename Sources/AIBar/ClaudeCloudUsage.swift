import Foundation
import CryptoKit

/// Fetches live official Claude quota via the OAuth usage endpoint, reading each
/// account's OAuth token from the macOS Keychain — the same storage the Claude Code
/// CLI uses. This covers accounts that are mostly used on web / desktop and rarely
/// run the CLI, which the local statusline files cannot reach.
///
/// Accounts to monitor are listed in `~/.ai-usage/claude-accounts.json`. When that
/// file is absent, this collector stays inactive and AIBar keeps its existing
/// statusline-based behaviour.
struct ClaudeCloudCollector {
    struct Result {
        var configured: Bool
        var accounts: [ProviderUsage]
        var errors: [String]
    }

    private let fileManager: FileManager
    private let now: Date

    init(fileManager: FileManager = .default, now: Date = Date()) {
        self.fileManager = fileManager
        self.now = now
    }

    func collect(localFallback: ProviderUsage) -> Result {
        let configs = loadAccountConfigs()
        guard !configs.isEmpty else {
            return Result(configured: false, accounts: [], errors: [])
        }

        let client = ClaudeCloudClient(now: now)
        var accounts: [ProviderUsage] = []
        var errors: [String] = []

        for config in configs {
            do {
                let usage = try client.fetchUsage(for: config)
                accounts.append(usage)
            } catch let error as ClaudeCloudError {
                accounts.append(pendingUsage(for: config, reason: error.userMessage))
                errors.append("\(config.label): \(error.userMessage)")
            } catch {
                accounts.append(pendingUsage(for: config, reason: error.localizedDescription))
                errors.append("\(config.label): \(error.localizedDescription)")
            }
        }

        // Local token totals (from ~/.claude/projects) belong to the default CLI
        // account and are attached to its statusline representation during the
        // merge in UsageCollector, so they are intentionally not applied here.
        return Result(configured: true, accounts: accounts, errors: errors)
    }

    private func pendingUsage(for config: ClaudeAccountConfig, reason: String) -> ProviderUsage {
        var usage = ProviderUsage(kind: .claude, accountName: config.label)
        usage.planType = "cloud"
        usage.note = reason
        return usage
    }

    private func loadAccountConfigs() -> [ClaudeAccountConfig] {
        let url = homeURL()
            .appendingPathComponent(".ai-usage", isDirectory: true)
            .appendingPathComponent("claude-accounts.json")
        guard
            let data = try? Data(contentsOf: url), !data.isEmpty,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawAccounts = object["accounts"] as? [[String: Any]]
        else {
            return []
        }

        return rawAccounts.enumerated().compactMap { index, entry in
            let configDir = (entry["configDir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let keychainService = (entry["keychainService"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let keychainAccount = (entry["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultLabel(configDir: configDir, index: index)
            return ClaudeAccountConfig(
                label: label,
                configDir: configDir,
                keychainServiceOverride: keychainService,
                keychainAccountOverride: keychainAccount
            )
        }
    }

    private func defaultLabel(configDir: String?, index: Int) -> String {
        guard let configDir else { return "default" }
        let name = (configDir as NSString).lastPathComponent
        return name.isEmpty ? "account\(index + 1)" : name
    }

    private func homeURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }
}

/// One monitored Claude account.
struct ClaudeAccountConfig {
    var label: String
    /// `CLAUDE_CONFIG_DIR` path for this account; nil means the default `~/.claude`.
    var configDir: String?
    /// Escape hatch: use this exact Keychain service instead of deriving it.
    var keychainServiceOverride: String?
    /// Escape hatch: Keychain account (`-a`) instead of `$USER`.
    var keychainAccountOverride: String?
}

enum ClaudeCloudError: Error {
    case noKeychainEntry
    case noClaudeLogin
    case tokenExpiredNoRefresh
    case refreshFailed(String)
    case httpError(Int, String)
    case malformedResponse
    case network(String)

    var userMessage: String {
        switch self {
        case .noKeychainEntry:
            return "找不到此帳號的 Keychain 憑證(請先在該 config dir 用 CLI 登入一次)"
        case .noClaudeLogin:
            return "此 Keychain 項目沒有 Claude 帳號登入(只有 MCP 憑證)"
        case .tokenExpiredNoRefresh:
            return "access token 已過期且無法刷新"
        case .refreshFailed(let detail):
            return "token 刷新失敗:\(detail)"
        case .httpError(let code, let detail):
            return "usage API 回應 HTTP \(code)\(detail.isEmpty ? "" : ":\(detail)")"
        case .malformedResponse:
            return "usage API 回應格式無法解析"
        case .network(let detail):
            return "連線錯誤:\(detail)"
        }
    }
}

/// Low-level client: Keychain read/write + usage/refresh HTTP calls. Synchronous,
/// intended to run on the background thread that `UsageCollector.collect()` uses.
struct ClaudeCloudClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthBeta = "oauth-2025-04-20"
    static let anthropicVersion = "2023-06-01"
    static let refreshSkewSeconds: TimeInterval = 120

    let now: Date

    func fetchUsage(for config: ClaudeAccountConfig) throws -> ProviderUsage {
        let service = config.keychainServiceOverride ?? Self.keychainService(configDir: config.configDir)
        let account = config.keychainAccountOverride ?? Self.keychainAccountName()

        guard let blob = readKeychain(service: service, account: account) else {
            throw ClaudeCloudError.noKeychainEntry
        }
        guard
            let root = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [String: Any],
            var oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken0 = oauth["accessToken"] as? String
        else {
            throw ClaudeCloudError.noClaudeLogin
        }

        var accessToken = accessToken0
        // Refresh proactively if the access token has expired (or is about to).
        if let expiresAtMS = intValue(oauth["expiresAt"]) {
            let expiresAt = Date(timeIntervalSince1970: Double(expiresAtMS) / 1000.0)
            if expiresAt.timeIntervalSince(now) <= Self.refreshSkewSeconds {
                accessToken = try refreshAndPersist(
                    root: root, oauth: &oauth, service: service, account: account
                )
            }
        }

        let usageJSON = try requestUsage(accessToken: accessToken)
        return providerUsage(from: usageJSON, label: config.label)
    }

    // MARK: - Keychain service naming (mirrors Claude Code g5())

    static func keychainService(configDir: String?) -> String {
        let base = "Claude Code-credentials"
        guard let configDir, !configDir.isEmpty else { return base }
        let defaultDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        if (configDir as NSString).standardizingPath == (defaultDir as NSString).standardizingPath {
            return base
        }
        let normalized = configDir.precomposedStringWithCanonicalMapping // NFC
        let hash = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        return "\(base)-\(hash)"
    }

    static func keychainAccountName() -> String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy(allowed.contains) && !name.isEmpty ? name : "claude-code-user"
    }

    // MARK: - Keychain I/O (shell out to /usr/bin/security to avoid ACL prompts)

    private func readKeychain(service: String, account: String) -> String? {
        let result = runSecurity(["find-generic-password", "-a", account, "-w", "-s", service])
        guard result.status == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeKeychain(service: String, account: String, json: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            throw ClaudeCloudError.refreshFailed("無法序列化更新後的憑證")
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let result = runSecurity(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        guard result.status == 0 else {
            throw ClaudeCloudError.refreshFailed("寫回 Keychain 失敗(security rc=\(result.status))")
        }
    }

    private func runSecurity(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    // MARK: - HTTP

    private func requestUsage(accessToken: String) throws -> [String: Any] {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let (data, response, error) = sendSynchronously(request)
        if let error { throw ClaudeCloudError.network(error.localizedDescription) }
        guard let response, let data else { throw ClaudeCloudError.malformedResponse }
        guard response.statusCode == 200 else {
            throw ClaudeCloudError.httpError(response.statusCode, snippet(data))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeCloudError.malformedResponse
        }
        return object
    }

    /// Returns the new access token and persists the rotated credentials to Keychain.
    private func refreshAndPersist(
        root: [String: Any],
        oauth: inout [String: Any],
        service: String,
        account: String
    ) throws -> String {
        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw ClaudeCloudError.tokenExpiredNoRefresh
        }
        let scopes = (oauth["scopes"] as? [String]) ?? []
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": scopes.joined(separator: " ")
        ]

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response, error) = sendSynchronously(request)
        if let error { throw ClaudeCloudError.refreshFailed(error.localizedDescription) }
        guard let response, let data else { throw ClaudeCloudError.refreshFailed("無回應") }
        guard response.statusCode == 200 else {
            throw ClaudeCloudError.refreshFailed("HTTP \(response.statusCode) \(snippet(data))")
        }
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let newAccess = object["access_token"] as? String
        else {
            throw ClaudeCloudError.refreshFailed("回應缺少 access_token")
        }

        // Re-read the freshest blob before writing, to avoid clobbering a concurrent
        // CLI refresh, then merge only the token fields we changed.
        var mergedRoot = root
        if
            let fresh = readKeychain(service: service, account: account),
            let freshRoot = (try? JSONSerialization.jsonObject(with: Data(fresh.utf8))) as? [String: Any]
        {
            mergedRoot = freshRoot
        }
        var mergedOauth = (mergedRoot["claudeAiOauth"] as? [String: Any]) ?? oauth
        mergedOauth["accessToken"] = newAccess
        if let newRefresh = object["refresh_token"] as? String, !newRefresh.isEmpty {
            mergedOauth["refreshToken"] = newRefresh
        }
        if let expiresIn = doubleValue(object["expires_in"]) {
            mergedOauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        }
        mergedRoot["claudeAiOauth"] = mergedOauth
        oauth = mergedOauth

        try writeKeychain(service: service, account: account, json: mergedRoot)
        return newAccess
    }

    private func sendSynchronously(_ request: URLRequest) -> (Data?, HTTPURLResponse?, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResponse: HTTPURLResponse?
        var outError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            outData = data
            outResponse = response as? HTTPURLResponse
            outError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return (outData, outResponse, outError)
    }

    private func snippet(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 200 ? String(text.prefix(200)) : text
    }

    // MARK: - Response mapping

    private func providerUsage(from json: [String: Any], label: String) -> ProviderUsage {
        var usage = ProviderUsage(kind: .claude, accountName: label)
        usage.planType = "cloud"
        usage.statuslineCapturedAt = now
        usage.latestEventAt = now
        usage.events = 1
        usage.sourceFiles = 1

        usage.primaryLimit = rateWindow(from: json["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
        usage.secondaryLimit = rateWindow(from: json["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)

        if usage.primaryLimit == nil, usage.secondaryLimit == nil {
            usage.note = "此帳號目前無 quota 資料"
        }
        return usage
    }

    private func rateWindow(from dictionary: [String: Any]?, windowMinutes: Int) -> RateWindow? {
        guard let dictionary else { return nil }
        let used = doubleValue(dictionary["utilization"])
        let resetsAt = parseISODate(dictionary["resets_at"] as? String)
        if let resetsAt, resetsAt <= now { return nil }
        guard used != nil || resetsAt != nil else { return nil }
        return RateWindow(usedPercent: used, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        // Strip fractional seconds (the API returns microseconds) so ISO8601 parses cleanly.
        let cleaned = value.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
