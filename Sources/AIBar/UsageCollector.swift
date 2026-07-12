import Foundation

private struct CodexRateLimitSnapshot {
    let timestamp: Date
    let primaryLimit: RateWindow?
    let secondaryLimit: RateWindow?
    let planType: String?
    let hasExpiredWindow: Bool
}

struct UsageCollector {
    private let fileManager: FileManager
    private let calendar: Calendar
    private let now: Date
    private let isoFormatter: ISO8601DateFormatter
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
        self.now = now
        self.environment = environment
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    func collect() -> UsageSnapshot {
        var snapshot = UsageSnapshot(capturedAt: now)
        let windows = TimeWindows(calendar: calendar, now: now)

        do {
            snapshot.codex = try collectCodex(
                windows: windows,
                currentAuthState: currentCodexAuthState()
            )
        } catch {
            snapshot.errors.append("Codex: \(error.localizedDescription)")
        }

        do {
            let currentClaudeAuthState = currentClaudeAuthState()
            let localClaude = try collectClaudeLocal(windows: windows, currentAuthState: currentClaudeAuthState)
            let statuslineAccounts = collectClaudeStatuslineAccounts(
                localFallback: localClaude,
                currentAuthState: currentClaudeAuthState
            )
            let cloud = ClaudeCloudCollector(fileManager: fileManager, now: now).collect(localFallback: localClaude)
            // Per-account cloud issues (rate limits, transient failures) surface as a
            // note on that account's card rather than in the alarming error panel.

            // Only the default account and explicitly-configured accounts surface as
            // cards. A non-default config dir that merely left a statusline file
            // (e.g. logged in manually outside AIBar) stays in the "add account" list
            // instead of appearing as an uninvited card.
            let cloudKeys = Set(cloud.accounts.map { mergeKey($0.claudeMergeKey ?? $0.accountName) })
            let visibleStatusline = statuslineAccounts.filter { account in
                let key = mergeKey(account.claudeMergeKey ?? account.accountName)
                return key == "default" || cloudKeys.contains(key)
            }

            if visibleStatusline.isEmpty && cloud.accounts.isEmpty {
                snapshot.claude = claudeCodePendingUsage(from: localClaude)
            } else {
                snapshot.claude = localClaude
                // Hybrid: CLI-active accounts keep their richer statusline data;
                // configured cloud accounts (web/desktop) contribute live quota.
                snapshot.claudeAccounts = mergeClaudeAccounts(
                    statusline: visibleStatusline,
                    cloud: cloud.accounts
                )
            }
        } catch {
            snapshot.errors.append("Claude: \(error.localizedDescription)")
        }

        return snapshot
    }

    private func collectCodex(
        windows: TimeWindows,
        currentAuthState: CodexAuthState?
    ) throws -> ProviderUsage {
        let roots = codexSessionRoots()
        var checkedRoots: [URL] = []

        for root in roots {
            checkedRoots.append(root)
            let usage = collectCodex(
                windows: windows,
                root: root,
                currentAuthState: currentAuthState
            )
            if usage.events > 0 {
                return usage
            }
        }

        var usage = ProviderUsage(kind: .codex)
        usage.note = codexNoEventsNote(roots: checkedRoots)
        return usage
    }

    private func collectCodex(
        windows: TimeWindows,
        root: URL,
        currentAuthState: CodexAuthState?
    ) -> ProviderUsage {
        var usage = ProviderUsage(kind: .codex)
        let files = recentJSONLFiles(under: root, modifiedAfter: windows.weekStart)
        usage.sourceFiles = files.count
        var latestLimitSnapshot: CodexRateLimitSnapshot?
        var observedPlanTypes = Set<String>()

        for file in files {
            for line in readLines(from: file) where line.contains("\"token_count\"") {
                guard
                    let object = parseJSONObject(line),
                    let payload = object["payload"] as? [String: Any],
                    payload["type"] as? String == "token_count",
                    let timestamp = parseTimestamp(object["timestamp"] as? String)
                else {
                    continue
                }

                let info = payload["info"] as? [String: Any]
                let last = tokenTotals(from: info?["last_token_usage"] as? [String: Any], includeCachedAsSeparate: true)

                if timestamp >= windows.weekStart {
                    usage.dailyTotals[windows.dayStart(for: timestamp), default: TokenTotals()].add(last)
                }
                if timestamp >= windows.todayStart {
                    usage.today.add(last)
                }
                if timestamp >= windows.fiveHoursAgo {
                    usage.rollingFiveHours.add(last)
                }

                usage.events += 1
                if usage.latestEventAt == nil || timestamp > usage.latestEventAt! {
                    usage.latestEventAt = timestamp
                }

                if
                    let rateLimits = payload["rate_limits"] as? [String: Any],
                    isMainCodexRateLimit(rateLimits)
                {
                    let primaryLimit = rateWindow(from: rateLimits["primary"] as? [String: Any])
                    let secondaryLimit = rateWindow(from: rateLimits["secondary"] as? [String: Any])
                    let planType = stringValue(rateLimits["plan_type"])
                    if let planType {
                        observedPlanTypes.insert(planType)
                    }

                    let candidate = CodexRateLimitSnapshot(
                        timestamp: timestamp,
                        primaryLimit: primaryLimit,
                        secondaryLimit: secondaryLimit,
                        planType: planType,
                        hasExpiredWindow: hasExpiredCodexRateWindow(rateLimits)
                    )
                    if latestLimitSnapshot == nil || timestamp > latestLimitSnapshot!.timestamp {
                        latestLimitSnapshot = candidate
                    }
                }
            }
        }

        guard let latestLimitSnapshot else {
            usage.note = "尚未收到 Codex 本機額度快照"
            return usage
        }

        usage.planType = latestLimitSnapshot.planType
        if observedPlanTypes.count > 1 {
            usage.note = codexPlanSelectionNote(
                observedPlanTypes: observedPlanTypes,
                latestPlanType: latestLimitSnapshot.planType,
                currentAuthState: currentAuthState
            )
        }

        if latestLimitSnapshot.hasExpiredWindow {
            usage.note = "Codex 本機額度快照已過重置時間；下一次 Codex 回覆後再同步"
            return usage
        }

        usage.primaryLimit = latestLimitSnapshot.primaryLimit
        usage.secondaryLimit = latestLimitSnapshot.secondaryLimit
        if usage.primaryLimit == nil && usage.secondaryLimit == nil {
            usage.note = "Codex 本機額度快照不含可顯示的額度"
        }
        return usage
    }

    /// Codex can emit a separate rate-limit bucket for an individual model
    /// (for example `codex_bengalfox` for GPT-5.3-Codex-Spark). The Codex card
    /// represents the account-wide quota, so a newer model-specific event must
    /// not replace the main `codex` window and make the card appear to be 100%.
    /// Older records did not always include `limit_id`, so keep accepting those.
    private func isMainCodexRateLimit(_ rateLimits: [String: Any]) -> Bool {
        guard let limitID = stringValue(rateLimits["limit_id"]) else {
            return true
        }
        return limitID == "codex"
    }

    private func hasExpiredCodexRateWindow(_ rateLimits: [String: Any]) -> Bool {
        ["primary", "secondary"].contains { key in
            guard
                let window = rateLimits[key] as? [String: Any],
                let reset = doubleValue(window["resets_at"]),
                reset > 0
            else {
                return false
            }
            return Date(timeIntervalSince1970: reset) <= now
        }
    }

    private func codexPlanSelectionNote(
        observedPlanTypes: Set<String>,
        latestPlanType: String?,
        currentAuthState: CodexAuthState?
    ) -> String {
        let latest = latestPlanType.map(codexPlanDisplayName) ?? "未知"
        var olderPlanTypes = observedPlanTypes
        if let latestPlanType {
            olderPlanTypes.remove(latestPlanType)
        }
        let older = olderPlanTypes
            .sorted()
            .map(codexPlanDisplayName)
            .joined(separator: "、")

        guard let authPlan = currentAuthState?.planType else {
            return "目前顯示最新 Codex 回覆回報的 \(latest) 額度；已略過較舊的 \(older) 快照"
        }

        let auth = codexPlanDisplayName(authPlan)
        let refresh = currentAuthState?.refreshedAt.map { DateFormatters.reset.string(from: $0) } ?? "未知時間"
        return "目前顯示最新 Codex 回覆回報的 \(latest) 額度；已略過較舊的 \(older) 快照。本機登入憑證仍標示 \(auth)（更新於 \(refresh)）"
    }

    private func codexPlanDisplayName(_ planType: String) -> String {
        switch planType.lowercased() {
        case "plus": return "Plus"
        case "pro", "prolite": return "Pro"
        default: return planType
        }
    }

    private func collectClaudeLocal(windows: TimeWindows, currentAuthState: ClaudeAuthState?) throws -> ProviderUsage {
        var usage = ProviderUsage(kind: .claude)
        let root = homeURL().appendingPathComponent(".claude/projects", isDirectory: true)
        let files = recentJSONLFiles(under: root, modifiedAfter: windows.weekStart)
        usage.sourceFiles = files.count
        var seenMessageIDs = Set<String>()

        for file in files {
            for line in readLines(from: file) where line.contains("\"usage\"") {
                guard
                    let object = parseJSONObject(line),
                    let timestamp = parseTimestamp(object["timestamp"] as? String),
                    let message = object["message"] as? [String: Any],
                    let usageDict = message["usage"] as? [String: Any]
                else {
                    continue
                }

                let messageID = (message["id"] as? String)
                    ?? (object["requestId"] as? String)
                    ?? (object["uuid"] as? String)
                    ?? "\(file.path)-\(timestamp.timeIntervalSince1970)-\(usage.events)"

                guard seenMessageIDs.insert(messageID).inserted else {
                    continue
                }

                let totals = tokenTotals(from: usageDict, includeCachedAsSeparate: true)

                if timestamp >= windows.weekStart {
                    usage.dailyTotals[windows.dayStart(for: timestamp), default: TokenTotals()].add(totals)
                }
                if timestamp >= windows.todayStart {
                    usage.today.add(totals)
                }
                if timestamp >= windows.fiveHoursAgo {
                    usage.rollingFiveHours.add(totals)
                }

                usage.events += 1
                if usage.latestEventAt == nil || timestamp > usage.latestEventAt! {
                    usage.latestEventAt = timestamp
                    usage.latestModel = message["model"] as? String
                }
            }
        }

        if let limitError = latestClaudeRateLimitError(
            in: files,
            notBefore: currentAuthState?.modifiedAt ?? windows.todayStart
        ) {
            usage.primaryLimit = limitError.limit
            usage.planType = "rate-limit-error"
            usage.limitErrorAt = limitError.timestamp
            usage.latestEventAt = maxDate(usage.latestEventAt, limitError.timestamp)
            if let reset = limitError.limit.resetsAt {
                usage.note = "Claude Code 回報已達 session limit；重置 \(DateFormatters.reset.string(from: reset))"
            } else {
                usage.note = "Claude Code 回報已達 session limit"
            }
        } else {
            usage.note = usage.events == 0 ? "找不到最近的 Claude usage 訊息" : "Claude 未在本機紀錄官方 quota / 剩餘百分比"
        }
        return usage
    }

    /// Union of statusline (CLI-active, richer) and cloud (web/desktop, live quota)
    /// accounts. When both describe the same account, statusline wins while it still
    /// carries fresh official limits; otherwise the live cloud reading is used.
    private func mergeClaudeAccounts(statusline: [ProviderUsage], cloud: [ProviderUsage]) -> [ProviderUsage] {
        guard !cloud.isEmpty else { return statusline }

        var order: [String] = []
        var chosen: [String: ProviderUsage] = [:]

        for account in statusline {
            let key = mergeKey(account.claudeMergeKey ?? account.accountName)
            if chosen[key] == nil { order.append(key) }
            chosen[key] = account
        }

        for account in cloud {
            let key = mergeKey(account.claudeMergeKey ?? account.accountName)
            if let existing = chosen[key] {
                if account.hasOfficialLimits {
                    // Both sources describe this account. The cloud reading is the
                    // authoritative live quota — it is polled continuously (even while
                    // idle), whereas the statusline snapshot freezes between Claude Code
                    // renders and under-reports recent usage. Prefer cloud, but keep the
                    // friendlier resolved label (e.g. the account email) when the cloud
                    // entry only has the generic config-dir name.
                    var live = account
                    let cloudLabel = live.accountName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cloudLabel == nil || cloudLabel!.isEmpty || cloudLabel == "default" {
                        if let slName = existing.accountName, !slName.isEmpty, slName != "default" {
                            live.accountName = slName
                        }
                    }
                    chosen[key] = live
                } else {
                    // Cloud has no usable limits (e.g. the API failed with no cached
                    // value). Keep the statusline reading, but adopt the friendlier
                    // configured label if it has one.
                    var kept = existing
                    if let label = account.accountName, !label.isEmpty, label != "default" {
                        kept.accountName = label
                    }
                    chosen[key] = kept
                }
            } else {
                order.append(key)
                chosen[key] = account
            }
        }

        return order.compactMap { chosen[$0] }
    }

    private func mergeKey(_ accountName: String?) -> String {
        let raw = accountName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let trimmed = raw.drop(while: { $0 == "." || $0 == "-" })
        return trimmed.isEmpty ? "default" : String(trimmed)
    }

    private func claudeCodePendingUsage(from localFallback: ProviderUsage) -> ProviderUsage {
        var usage = localFallback
        usage.accountName = "Code"
        if usage.planType == "rate-limit-error" {
            return usage
        }
        // Never synthesize Claude Code quota from Desktop cache or local token logs.
        // If official statusline limits are unavailable, show an unsynced state.
        usage.primaryLimit = nil
        usage.secondaryLimit = nil
        usage.planType = "statusline"
        usage.statuslineCapturedAt = nil
        usage.note = "尚未收到 Claude Code 官方 limits；請重啟 Claude Code 或送出一則訊息後再重新整理"
        return usage
    }

    private func collectClaudeStatuslineAccounts(
        localFallback: ProviderUsage,
        currentAuthState: ClaudeAuthState?
    ) -> [ProviderUsage] {
        let root = homeURL()
            .appendingPathComponent(".ai-usage", isDirectory: true)
            .appendingPathComponent("claude-status", isDirectory: true)

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var accounts: [ProviderUsage] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "json" else { continue }
            guard let object = readJSONObject(from: file) else { continue }

            let accountName = stringValue(object["account"])
                ?? file.deletingPathExtension().lastPathComponent

            var usage = ProviderUsage(kind: .claude, accountName: accountName)
            usage.sourceFiles = 1
            usage.events = 1
            usage.planType = "statusline"
            usage.statuslineCapturedAt = parseDateValue(object["captured_at"])
                ?? modificationDate(for: file)
            usage.latestEventAt = usage.statuslineCapturedAt
            let authStaleReason = claudeAuthStaleReason(
                snapshot: object,
                accountName: accountName,
                capturedAt: usage.statuslineCapturedAt,
                currentAuthState: currentAuthState
            )

            if let model = object["model"] as? [String: Any] {
                usage.latestModel = stringValue(model["display_name"]) ?? stringValue(model["id"])
            }

            let rateLimits = object["rate_limits"] as? [String: Any]
            if authStaleReason == nil, let rateLimits {
                usage.primaryLimit = claudeRateWindow(from: rateLimits["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
                usage.secondaryLimit = claudeRateWindow(from: rateLimits["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)
            }

            if let context = object["context_window"] as? [String: Any] {
                usage.liveContext = liveContextTotals(from: context)
            }

            if let cost = object["cost"] as? [String: Any] {
                usage.sessionCostUSD = doubleValue(cost["total_cost_usd"])
            }

            usage.note = authStaleReason
                ?? claudeStatuslineNote(for: usage, hadRateLimits: rateLimits != nil)
                ?? claudeStatuslineFreshnessNote(capturedAt: usage.statuslineCapturedAt)

            // The default account's name is just "default"; show its real email
            // (resolved from the profile endpoint, cached) while keeping its merge
            // identity as "default" so it still passes the visibility filter.
            if mergeKey(accountName) == "default" {
                usage.claudeMergeKey = "default"
                if let email = ClaudeCloudClient(now: now).cachedEmail(configDir: nil), !email.isEmpty {
                    usage.accountName = email
                }
            }

            applyClaudeRateLimitErrorOverride(from: localFallback, to: &usage)
            accounts.append(usage)
        }

        var sortedAccounts = accounts.sorted {
            ($0.statuslineCapturedAt ?? .distantPast) > ($1.statuslineCapturedAt ?? .distantPast)
        }

        if sortedAccounts.count == 1, localFallback.events > 0 {
            sortedAccounts[0].today = localFallback.today
            sortedAccounts[0].rollingFiveHours = localFallback.rollingFiveHours
            sortedAccounts[0].dailyTotals = localFallback.dailyTotals
            sortedAccounts[0].sourceFiles += localFallback.sourceFiles
            sortedAccounts[0].events += localFallback.events
        }

        return sortedAccounts
    }

    private func applyClaudeRateLimitErrorOverride(from localFallback: ProviderUsage, to usage: inout ProviderUsage) {
        guard
            localFallback.planType == "rate-limit-error",
            let limitErrorAt = localFallback.limitErrorAt,
            let localPrimaryLimit = localFallback.primaryLimit
        else {
            return
        }

        let statuslineCapturedAt = usage.statuslineCapturedAt ?? .distantPast
        guard limitErrorAt >= statuslineCapturedAt else { return }

        usage.primaryLimit = localPrimaryLimit
        usage.secondaryLimit = nil
        usage.planType = localFallback.planType
        usage.limitErrorAt = limitErrorAt
        usage.note = localFallback.note
    }

    private func latestClaudeRateLimitError(in files: [URL], notBefore: Date) -> ClaudeRateLimitError? {
        var latest: ClaudeRateLimitError?

        for file in files {
            for line in readLines(from: file) where line.contains("\"rate_limit\"") || line.contains("\"apiErrorStatus\":429") {
                guard
                    let object = parseJSONObject(line),
                    let timestamp = parseTimestamp(object["timestamp"] as? String),
                    timestamp >= notBefore,
                    (object["error"] as? String == "rate_limit" || intValue(object["apiErrorStatus"]) == 429),
                    let text = claudeMessageText(from: object)
                else {
                    continue
                }

                guard let resetsAt = parseClaudeRateLimitReset(from: text, reference: timestamp), resetsAt > now else {
                    continue
                }

                let candidate = ClaudeRateLimitError(
                    timestamp: timestamp,
                    limit: RateWindow(usedPercent: 100, windowMinutes: 5 * 60, resetsAt: resetsAt)
                )

                if latest == nil || candidate.timestamp > latest!.timestamp {
                    latest = candidate
                }
            }
        }

        return latest
    }

    private func claudeMessageText(from object: [String: Any]) -> String? {
        guard
            let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else {
            return nil
        }

        let text = content
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func parseClaudeRateLimitReset(from text: String, reference: Date) -> Date? {
        let pattern = #"resets\s+([0-9]{1,2}:[0-9]{2}\s*(?:am|pm|AM|PM))(?:\s*\(([^)]+)\))?"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let timeRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        let timeZone: TimeZone
        if
            match.numberOfRanges > 2,
            let zoneRange = Range(match.range(at: 2), in: text),
            let parsedZone = TimeZone(identifier: String(text[zoneRange]))
        {
            timeZone = parsedZone
        } else {
            timeZone = .current
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mma"

        let compactTime = String(text[timeRange]).replacingOccurrences(of: " ", with: "").uppercased()
        guard let parsedTime = formatter.date(from: compactTime) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: reference)
        let time = calendar.dateComponents([.hour, .minute], from: parsedTime)
        var components = DateComponents()
        components.timeZone = timeZone
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = time.hour
        components.minute = time.minute

        guard var reset = calendar.date(from: components) else {
            return nil
        }

        if reset <= reference.addingTimeInterval(-60) {
            reset = calendar.date(byAdding: .day, value: 1, to: reset) ?? reset
        }

        return reset
    }

    private func currentClaudeAuthState() -> ClaudeAuthState? {
        let configFile = homeURL().appendingPathComponent(".claude.json")
        guard
            let object = readJSONObject(from: configFile),
            let oauth = object["oauthAccount"] as? [String: Any]
        else {
            return nil
        }

        return ClaudeAuthState(
            email: stringValue(oauth["emailAddress"]),
            organizationID: stringValue(oauth["organizationUuid"]),
            organizationName: stringValue(oauth["organizationName"]),
            modifiedAt: modificationDate(for: configFile)
        )
    }

    /// The login token exposes the plan recorded when Codex last refreshed its
    /// credentials. It is useful as an identity signal, but not as a quota
    /// source: an entitlement can change before this cached token is refreshed.
    private func currentCodexAuthState() -> CodexAuthState? {
        let authFile = homeURL().appendingPathComponent(".codex/auth.json")
        guard let object = readJSONObject(from: authFile) else { return nil }

        let refreshedAt = parseTimestamp(stringValue(object["last_refresh"]))
        guard
            let tokens = object["tokens"] as? [String: Any],
            let idToken = stringValue(tokens["id_token"]),
            let payload = jwtPayload(idToken),
            let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        else {
            return CodexAuthState(planType: nil, refreshedAt: refreshedAt)
        }

        return CodexAuthState(
            planType: stringValue(auth["chatgpt_plan_type"]),
            refreshedAt: refreshedAt
        )
    }

    private func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func claudeAuthStaleReason(
        snapshot: [String: Any],
        accountName: String,
        capturedAt: Date?,
        currentAuthState: ClaudeAuthState?
    ) -> String? {
        guard let currentAuthState else { return nil }

        if let snapshotAuth = snapshot["auth"] as? [String: Any] {
            let snapshotEmail = stringValue(snapshotAuth["email"])
            let snapshotOrganizationID = stringValue(snapshotAuth["organization_uuid"])
            if snapshotEmail != currentAuthState.email || snapshotOrganizationID != currentAuthState.organizationID {
                return "Claude 已登入 \(currentAuthState.displayName)；需等下一次 Claude Code 回覆後更新官方 limits"
            }
            return nil
        }

        guard accountName == "default", let capturedAt, let authModifiedAt = currentAuthState.modifiedAt else {
            return nil
        }

        if authModifiedAt > capturedAt.addingTimeInterval(1) {
            return "Claude 登入狀態已於 \(DateFormatters.reset.string(from: authModifiedAt)) 變更；需等下一次 Claude Code 回覆後更新官方 limits"
        }

        return nil
    }

    private func recentJSONLFiles(under root: URL, modifiedAfter date: Date) -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var files: [URL] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl" else { continue }
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            guard (values.contentModificationDate ?? .distantPast) >= date else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func readLines(from file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            return []
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readJSONObject(from file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = isoFormatter.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private func tokenTotals(from dictionary: [String: Any]?, includeCachedAsSeparate: Bool) -> TokenTotals {
        guard let dictionary else { return TokenTotals() }
        let input = intValue(dictionary["input_tokens"])
        let output = intValue(dictionary["output_tokens"])
        let cacheCreation = intValue(dictionary["cache_creation_input_tokens"])
        let cacheRead = intValue(dictionary["cache_read_input_tokens"])
        let reasoning = intValue(dictionary["reasoning_output_tokens"])

        return TokenTotals(
            input: input,
            cachedInput: includeCachedAsSeparate ? cacheCreation + cacheRead : 0,
            output: output,
            reasoningOutput: reasoning
        )
    }

    private func rateWindow(from dictionary: [String: Any]?) -> RateWindow? {
        guard let dictionary else { return nil }
        let usedPercent = doubleValue(dictionary["used_percent"])
        let reset = intValue(dictionary["resets_at"])
        let resetsAt = reset > 0 ? Date(timeIntervalSince1970: TimeInterval(reset)) : nil
        let isExpired = resetsAt.map { $0 <= now } ?? false
        guard usedPercent != nil || (resetsAt != nil && !isExpired) else {
            return nil
        }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: intValue(dictionary["window_minutes"]),
            resetsAt: resetsAt,
            isExpired: isExpired
        )
    }

    private func claudeRateWindow(from dictionary: [String: Any]?, windowMinutes: Int) -> RateWindow? {
        guard let dictionary else { return nil }
        let reset = doubleValue(dictionary["resets_at"])
        let resetsAt = (reset ?? 0) > 0 ? Date(timeIntervalSince1970: reset ?? 0) : nil
        let usedPercent = doubleValue(dictionary["used_percentage"])
        let isExpired = resetsAt.map { $0 <= now } ?? false

        if isExpired {
            // The window already reset; the CLI is echoing the pre-reset numbers
            // until the next activity. Keep the last-known value visible but dimmed
            // as "待更新" (matching Codex) instead of dropping it to a bare "--".
            guard usedPercent != nil else { return nil }
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt,
                isExpired: true
            )
        }

        guard usedPercent != nil || resetsAt != nil else { return nil }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    private func liveContextTotals(from context: [String: Any]) -> TokenTotals {
        if let current = context["current_usage"] as? [String: Any] {
            return tokenTotals(from: current, includeCachedAsSeparate: true)
        }

        return TokenTotals(
            input: intValue(context["total_input_tokens"]),
            output: intValue(context["total_output_tokens"])
        )
    }

    private func claudeStatuslineNote(for usage: ProviderUsage, hadRateLimits: Bool) -> String? {
        let windows = [usage.primaryLimit, usage.secondaryLimit].compactMap { $0 }
        if windows.isEmpty {
            if hadRateLimits {
                return "Claude 官方 rate limit reset window 已過期；下一次 Claude Code 回覆後更新"
            }
            return "尚未收到 Claude Code 官方 rate_limits；送出一次訊息後更新"
        }

        if windows.allSatisfy({ $0.usedPercent == nil }) {
            return "Claude rate limit 資料已過期；打開該帳號的 Claude Code 後會更新"
        }

        return nil
    }

    private func claudeStatuslineFreshnessNote(capturedAt: Date?) -> String? {
        guard let capturedAt else {
            return nil
        }

        if now.timeIntervalSince(capturedAt) > 5 * 60 {
            return "Claude 官方資料最後同步於 \(DateFormatters.reset.string(from: capturedAt))；閒置中，下一次 Claude Code 回覆後刷新"
        }

        return nil
    }

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        return nil
    }

    private func parseDateValue(_ value: Any?) -> Date? {
        if let timestamp = doubleValue(value) {
            return Date(timeIntervalSince1970: timestamp)
        }
        return parseTimestamp(stringValue(value))
    }

    private func modificationDate(for file: URL) -> Date? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private func codexSessionRoots() -> [URL] {
        var roots: [URL] = []
        if let configuredHome = configuredCodexHomeURL() {
            roots.append(configuredHome.appendingPathComponent("sessions", isDirectory: true))
        }
        roots.append(homeURL().appendingPathComponent(".codex/sessions", isDirectory: true))
        return uniqueURLs(roots)
    }

    private func configuredCodexHomeURL() -> URL? {
        guard
            let rawPath = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: expandedHomePath(rawPath), isDirectory: true)
            .standardizedFileURL
    }

    private func expandedHomePath(_ path: String) -> String {
        if path == "~" {
            return homeURL().path
        }
        if path.hasPrefix("~/") {
            return homeURL().appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private func codexNoEventsNote(roots: [URL]) -> String {
        let checked = roots.map(codexDisplayPath).joined(separator: "、")
        return "找不到最近的 Codex token_count 事件；已檢查 \(checked)"
    }

    private func codexDisplayPath(_ url: URL) -> String {
        let standardizedPath = url.standardizedFileURL.path
        if let configuredHome = configuredCodexHomeURL() {
            let configuredSessions = configuredHome
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL
                .path
            if standardizedPath == configuredSessions {
                return "$CODEX_HOME/sessions"
            }
        }

        let defaultSessions = homeURL()
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .standardizedFileURL
            .path
        if standardizedPath == defaultSessions {
            return "~/.codex/sessions"
        }

        return standardizedPath
    }

    private func homeURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }
}

private struct TimeWindows {
    let calendar: Calendar
    let now: Date
    let todayStart: Date
    let weekStart: Date
    let fiveHoursAgo: Date

    init(calendar: Calendar, now: Date) {
        self.calendar = calendar
        self.now = now
        self.todayStart = calendar.startOfDay(for: now)
        self.weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        self.fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
    }

    func dayStart(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}

private struct ClaudeAuthState {
    let email: String?
    let organizationID: String?
    let organizationName: String?
    let modifiedAt: Date?

    var displayName: String {
        if let email {
            return email
        }
        if let organizationName {
            return organizationName
        }
        return "目前帳號"
    }
}

private struct CodexAuthState {
    let planType: String?
    let refreshedAt: Date?
}

private struct ClaudeRateLimitError {
    let timestamp: Date
    let limit: RateWindow
}
