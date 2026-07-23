import Foundation

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
        usage.claudeMergeKey = ClaudeCloudClient.statuslineName(configDir: config.configDir)
        usage.planType = "cloud"
        usage.note = reason
        return usage
    }

    private func loadAccountConfigs() -> [ClaudeAccountConfig] {
        let url = homeURL()
            .appendingPathComponent(".ai-usage", isDirectory: true)
            .appendingPathComponent("claude-accounts.json")
        guard
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(ClaudeAccountsFile.self, from: data)
        else {
            return []
        }

        return file.accounts.enumerated().map { index, entry in
            let configDir = entry.configDir.flatMap { $0.isEmpty ? nil : $0 }
            let label = entry.label.isEmpty ? defaultLabel(configDir: configDir, index: index) : entry.label
            return ClaudeAccountConfig(
                label: label,
                configDir: configDir,
                keychainServiceOverride: entry.keychainService.flatMap { $0.isEmpty ? nil : $0 },
                keychainAccountOverride: entry.account.flatMap { $0.isEmpty ? nil : $0 }
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
        case .httpError(let code, _):
            if code == 429 { return "官方 API 暫時限流,稍後自動重試" }
            if code == 401 { return "授權失效,請重新登入該帳號" }
            return "usage API 回應 HTTP \(code)"
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
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthBeta = "oauth-2025-04-20"
    static let anthropicVersion = "2023-06-01"
    static let refreshSkewSeconds: TimeInterval = 120
    /// Minimum spacing between usage-endpoint calls per account. Quota moves slowly
    /// (5h / 7d windows), so a 2-minute freshness is plenty. Because this is longer
    /// than the 60s UI refresh, roughly half the periodic refreshes — plus every
    /// popover-open / wake burst — are served straight from cache and never touch
    /// the API, which is what keeps the endpoint from returning HTTP 429. The cache
    /// also doubles as a last-known-value fallback when a fetch fails.
    static let pollInterval: TimeInterval = 120
    /// After the endpoint rate-limits an account (HTTP 429), hold off on further API
    /// calls for this long so the periodic refresh does not keep hammering it every
    /// 60s. Until then the last synced value stays visible with a "限流" note.
    static let backoffInterval: TimeInterval = 300

    /// The OAuth client id used for token refresh. Mirrors the CLI: an explicit
    /// `CLAUDE_CODE_OAUTH_CLIENT_ID` wins, otherwise the production client id.
    static var clientID: String {
        let override = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_CLIENT_ID"]
        if let override, !override.isEmpty { return override }
        return defaultClientID
    }

    let now: Date

    func fetchUsage(for config: ClaudeAccountConfig) throws -> ProviderUsage {
        let service = config.keychainServiceOverride ?? ClaudeKeychain.serviceName(configDir: config.configDir)
        let account = config.keychainAccountOverride ?? ClaudeKeychain.accountName()
        let mergeKey = Self.statuslineName(configDir: config.configDir)

        func build(_ json: [String: Any], capturedAt: Date, note: String?) -> ProviderUsage {
            var usage = providerUsage(from: json, label: config.label, capturedAt: capturedAt, note: note)
            usage.claudeMergeKey = mergeKey
            return usage
        }

        let cached = readCache(service: service)

        // Serve a recent reading straight from cache — quota moves slowly and the
        // endpoint rate-limits frequent polling.
        if let cached, now.timeIntervalSince(cached.capturedAt) < Self.pollInterval {
            return build(cached.json, capturedAt: cached.capturedAt, note: nil)
        }

        // This account was recently rate-limited: hold off on hitting the API until
        // the backoff expires, and keep showing the last synced value meanwhile.
        if let cached, let until = cached.backoffUntil, now < until {
            return build(cached.json, capturedAt: cached.capturedAt, note: staleNote(for: .httpError(429, "")))
        }

        guard
            let blob = ClaudeKeychain.read(service: service, account: account),
            let root = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [String: Any],
            var oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken0 = oauth["accessToken"] as? String
        else {
            if let cached {
                return build(cached.json, capturedAt: cached.capturedAt, note: "找不到有效憑證,顯示上次同步值")
            }
            throw ClaudeCloudError.noKeychainEntry
        }

        var accessToken = accessToken0
        // Refresh proactively if the access token has expired (or is about to).
        if let expiresAtMS = intValue(oauth["expiresAt"]) {
            let expiresAt = Date(timeIntervalSince1970: Double(expiresAtMS) / 1000.0)
            if expiresAt.timeIntervalSince(now) <= Self.refreshSkewSeconds {
                do {
                    accessToken = try refreshAndPersist(root: root, oauth: &oauth, service: service, account: account)
                } catch {
                    if let cached {
                        return build(cached.json, capturedAt: cached.capturedAt, note: "token 刷新失敗,顯示上次同步值")
                    }
                    throw error
                }
            }
        }

        do {
            let usageJSON = try requestUsage(accessToken: accessToken)
            writeCache(service: service, json: usageJSON)
            return build(usageJSON, capturedAt: now, note: nil)
        } catch let error as ClaudeCloudError {
            if case .httpError(429, _) = error {
                markBackoff(service: service)
            }
            if let cached {
                return build(cached.json, capturedAt: cached.capturedAt, note: staleNote(for: error))
            }
            throw error
        }
    }

    /// Resolves an account's email from /api/oauth/profile, cached for a long time
    /// (email rarely changes). Used to give the default account a proper label
    /// without adding meaningful API load. Returns nil if unavailable.
    func cachedEmail(configDir: String?) -> String? {
        let service = ClaudeKeychain.serviceName(configDir: configDir)
        let url = cacheURL(service: "email-\(service)")

        if
            let data = try? Data(contentsOf: url),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let timestamp = doubleValue(object["captured_at"]),
            now.timeIntervalSince(Date(timeIntervalSince1970: timestamp)) < 3600
        {
            return object["email"] as? String
        }

        guard
            let blob = ClaudeKeychain.read(service: service, account: ClaudeKeychain.accountName()),
            let root = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            let profile = fetchProfile(accessToken: token),
            let email = profile.email
        else {
            // Fall back to a stale cached email if the lookup fails.
            if
                let data = try? Data(contentsOf: url),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                return object["email"] as? String
            }
            return nil
        }

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["captured_at": now.timeIntervalSince1970, "email": email]) {
            try? data.write(to: url, options: .atomic)
        }
        return email
    }

    private func staleNote(for error: ClaudeCloudError) -> String {
        if case .httpError(429, _) = error {
            return "官方 API 暫時限流,顯示上次同步值"
        }
        return "暫時無法更新,顯示上次同步值"
    }

    // MARK: - Usage cache (gentle polling + last-known fallback)

    private var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-usage", isDirectory: true)
            .appendingPathComponent("claude-cloud-cache", isDirectory: true)
    }

    private func cacheURL(service: String) -> URL {
        let safe = service.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression)
        return cacheDirectory.appendingPathComponent("\(safe).json")
    }

    private func readCache(service: String) -> (capturedAt: Date, json: [String: Any], backoffUntil: Date?)? {
        guard
            let data = try? Data(contentsOf: cacheURL(service: service)),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let timestamp = doubleValue(object["captured_at"]),
            let usage = object["usage"] as? [String: Any]
        else {
            return nil
        }
        let backoffUntil = doubleValue(object["backoff_until"]).map { Date(timeIntervalSince1970: $0) }
        return (Date(timeIntervalSince1970: timestamp), usage, backoffUntil)
    }

    private func writeCache(service: String, json: [String: Any]) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // A successful fetch clears any prior backoff by omitting backoff_until.
        let payload: [String: Any] = ["captured_at": now.timeIntervalSince1970, "usage": json]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: cacheURL(service: service), options: .atomic)
    }

    /// Records a rate-limit backoff into the existing cache file, preserving the last
    /// successful snapshot (captured_at / usage) so the displayed value and its sync
    /// time stay intact while API calls are paused.
    private func markBackoff(service: String) {
        guard
            let data = try? Data(contentsOf: cacheURL(service: service)),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }
        object["backoff_until"] = now.timeIntervalSince1970 + Self.backoffInterval
        guard let out = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? out.write(to: cacheURL(service: service), options: .atomic)
    }

    /// The account name the statusline hook would derive for a config dir, used to
    /// dedupe cloud accounts against statusline accounts. Mirrors the hook: the
    /// default dir is "default"; otherwise the dir's basename with unsafe
    /// characters collapsed to "-" and leading/trailing ".-" trimmed.
    static func statuslineName(configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return "default" }
        let base = (configDir as NSString).lastPathComponent
        let collapsed = base.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? "default" : String(trimmed.prefix(80))
    }

    // MARK: - HTTP

    /// The authoritative account identity for a token. `~/.claude.json` can be
    /// stale, so this is the source of truth for which account a token belongs to.
    func fetchProfile(accessToken: String) -> (email: String?, organizationName: String?)? {
        var request = URLRequest(url: Self.profileURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let (data, response, _) = sendSynchronously(request)
        guard
            let response, response.statusCode == 200, let data,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        let account = object["account"] as? [String: Any]
        let organization = object["organization"] as? [String: Any]
        return (account?["email"] as? String, organization?["name"] as? String)
    }

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
        // Refresh must use the same client_id the token was issued under. Honour the
        // CLI's CLAUDE_CODE_OAUTH_CLIENT_ID override; otherwise use the production id.

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
            let fresh = ClaudeKeychain.read(service: service, account: account),
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

        guard ClaudeKeychain.write(service: service, account: account, json: mergedRoot) else {
            throw ClaudeCloudError.refreshFailed("寫回 Keychain 失敗")
        }
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
        // URLSession's request timeout does not guarantee that every failure path
        // (notably DNS/network transitions after wake) invokes the completion
        // handler promptly. Never let one Claude request wedge the whole collector:
        // while this call is blocked, Codex snapshots cannot be published and the
        // UI remains frozen at its previous percentage.
        let deadline = DispatchTime.now() + max(request.timeoutInterval + 2, 5)
        if semaphore.wait(timeout: deadline) == .timedOut {
            task.cancel()
            return (nil, nil, URLError(.timedOut))
        }
        return (outData, outResponse, outError)
    }

    private func snippet(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 200 ? String(text.prefix(200)) : text
    }

    // MARK: - Response mapping

    private func providerUsage(from json: [String: Any], label: String, capturedAt: Date, note: String?) -> ProviderUsage {
        var usage = ProviderUsage(kind: .claude, accountName: label)
        usage.planType = "cloud"
        usage.statuslineCapturedAt = capturedAt
        usage.latestEventAt = capturedAt
        usage.events = 1
        usage.sourceFiles = 1

        usage.primaryLimit = rateWindow(from: json["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
        usage.secondaryLimit = rateWindow(from: json["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)
        usage.scopedLimits = scopedLimits(from: json["limits"] as? [[String: Any]])

        if usage.primaryLimit == nil, usage.secondaryLimit == nil {
            usage.note = note ?? "此帳號目前無 quota 資料"
        } else {
            usage.note = note
        }
        return usage
    }

    /// Extracts per-model weekly windows from the official `limits` array. Each
    /// entry with `kind == "weekly_scoped"` carries a `scope.model.display_name`
    /// (e.g. "Fable") plus its own `percent`/`resets_at`. Overall entries
    /// (`weekly_all`, session) are ignored here — they map to the primary/secondary
    /// windows already read from the top-level `five_hour`/`seven_day` fields.
    private func scopedLimits(from limits: [[String: Any]]?) -> [ScopedLimit] {
        guard let limits else { return [] }
        return limits.compactMap { entry -> ScopedLimit? in
            guard (entry["kind"] as? String) == "weekly_scoped" else { return nil }
            guard
                let scope = entry["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let label = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                !label.isEmpty
            else { return nil }

            let used = doubleValue(entry["percent"])
            let resetsAt = parseISODate(entry["resets_at"] as? String)
            let isExpired = resetsAt.map { $0 <= now } ?? false
            guard used != nil || resetsAt != nil else { return nil }

            let window = RateWindow(
                usedPercent: used,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetsAt,
                isExpired: isExpired
            )
            return ScopedLimit(label: label, window: window)
        }
    }

    private func rateWindow(from dictionary: [String: Any]?, windowMinutes: Int) -> RateWindow? {
        guard let dictionary else { return nil }
        let used = doubleValue(dictionary["utilization"])
        let resetsAt = parseISODate(dictionary["resets_at"] as? String)
        let isExpired = resetsAt.map { $0 <= now } ?? false

        if isExpired {
            // Window already reset; keep the last-known value visible but dimmed as
            // "待更新" (matching Codex) instead of dropping it to a bare "--".
            guard used != nil else { return nil }
            return RateWindow(usedPercent: used, windowMinutes: windowMinutes, resetsAt: resetsAt, isExpired: true)
        }

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
