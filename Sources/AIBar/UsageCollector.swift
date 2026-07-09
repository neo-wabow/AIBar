import Foundation

struct UsageCollector {
    private let fileManager: FileManager
    private let calendar: Calendar
    private let now: Date
    private let isoFormatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default, now: Date = Date()) {
        self.fileManager = fileManager
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
        self.now = now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    func collect() -> UsageSnapshot {
        var snapshot = UsageSnapshot(capturedAt: now)
        let windows = TimeWindows(calendar: calendar, now: now)

        do {
            snapshot.codex = try collectCodex(windows: windows)
        } catch {
            snapshot.errors.append("Codex: \(error.localizedDescription)")
        }

        do {
            let localClaude = try collectClaudeLocal(windows: windows)
            let statuslineAccounts = collectClaudeStatuslineAccounts(localFallback: localClaude)
            if statuslineAccounts.isEmpty {
                snapshot.claude = claudeCodePendingUsage(from: localClaude)
            } else {
                snapshot.claude = localClaude
                snapshot.claudeAccounts = statuslineAccounts
            }
        } catch {
            snapshot.errors.append("Claude: \(error.localizedDescription)")
        }

        return snapshot
    }

    private func collectCodex(windows: TimeWindows) throws -> ProviderUsage {
        var usage = ProviderUsage(kind: .codex)
        let root = homeURL().appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = recentJSONLFiles(under: root, modifiedAfter: windows.weekStart)
        usage.sourceFiles = files.count
        var latestLimitEventAt: Date?

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

                if let rateLimits = payload["rate_limits"] as? [String: Any] {
                    let primaryLimit = rateWindow(from: rateLimits["primary"] as? [String: Any])
                    let secondaryLimit = rateWindow(from: rateLimits["secondary"] as? [String: Any])
                    if primaryLimit != nil || secondaryLimit != nil {
                        if latestLimitEventAt == nil || timestamp > latestLimitEventAt! {
                            latestLimitEventAt = timestamp
                            usage.primaryLimit = primaryLimit
                            usage.secondaryLimit = secondaryLimit
                            usage.planType = rateLimits["plan_type"] as? String
                        }
                    } else if latestLimitEventAt == nil {
                        usage.planType = rateLimits["plan_type"] as? String
                    }
                }
            }
        }

        usage.note = usage.events == 0 ? "找不到最近的 Codex token_count 事件" : nil
        return usage
    }

    private func collectClaudeLocal(windows: TimeWindows) throws -> ProviderUsage {
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

        usage.note = usage.events == 0 ? "找不到最近的 Claude usage 訊息" : "Claude 未在本機紀錄官方 quota / 剩餘百分比"
        return usage
    }

    private func claudeCodePendingUsage(from localFallback: ProviderUsage) -> ProviderUsage {
        var usage = localFallback
        usage.accountName = "Code"
        // Never synthesize Claude Code quota from Desktop cache or local token logs.
        // If official statusline limits are unavailable, show an unsynced state.
        usage.primaryLimit = nil
        usage.secondaryLimit = nil
        usage.planType = "statusline"
        usage.statuslineCapturedAt = nil
        usage.note = "尚未收到 Claude Code 官方 limits；請重啟 Claude Code 或送出一則訊息後再重新整理"
        return usage
    }

    private func collectClaudeStatuslineAccounts(localFallback: ProviderUsage) -> [ProviderUsage] {
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

            if let model = object["model"] as? [String: Any] {
                usage.latestModel = stringValue(model["display_name"]) ?? stringValue(model["id"])
            }

            if let rateLimits = object["rate_limits"] as? [String: Any] {
                if let capturedAt = usage.statuslineCapturedAt, now.timeIntervalSince(capturedAt) <= 5 * 60 {
                    usage.primaryLimit = claudeRateWindow(from: rateLimits["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
                    usage.secondaryLimit = claudeRateWindow(from: rateLimits["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)
                }
            }

            if let context = object["context_window"] as? [String: Any] {
                usage.liveContext = liveContextTotals(from: context)
            }

            if let cost = object["cost"] as? [String: Any] {
                usage.sessionCostUSD = doubleValue(cost["total_cost_usd"])
            }

            usage.note = claudeStatuslineNote(for: usage)
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
        let reset = intValue(dictionary["resets_at"])
        let resetsAt = reset > 0 ? Date(timeIntervalSince1970: TimeInterval(reset)) : nil
        if let resetsAt, resetsAt <= now {
            return nil
        }
        return RateWindow(
            usedPercent: doubleValue(dictionary["used_percent"]),
            windowMinutes: intValue(dictionary["window_minutes"]),
            resetsAt: resetsAt
        )
    }

    private func claudeRateWindow(from dictionary: [String: Any]?, windowMinutes: Int) -> RateWindow? {
        guard let dictionary else { return nil }
        let reset = doubleValue(dictionary["resets_at"])
        let resetsAt = (reset ?? 0) > 0 ? Date(timeIntervalSince1970: reset ?? 0) : nil
        if let resetsAt, resetsAt <= now {
            return nil
        }
        let usedPercent = doubleValue(dictionary["used_percentage"])

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

    private func claudeStatuslineNote(for usage: ProviderUsage) -> String? {
        if let capturedAt = usage.statuslineCapturedAt, now.timeIntervalSince(capturedAt) > 5 * 60 {
            return "官方資料來自 \(DateFormatters.reset.string(from: capturedAt))，已視為過期；該帳號下一次回覆後會刷新"
        }

        let windows = [usage.primaryLimit, usage.secondaryLimit].compactMap { $0 }
        if windows.isEmpty {
            return "尚未收到 Claude Code 官方 rate_limits；送出一次訊息後更新"
        }

        if windows.allSatisfy({ $0.usedPercent == nil }) {
            return "Claude rate limit 資料已過期；打開該帳號的 Claude Code 後會更新"
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
