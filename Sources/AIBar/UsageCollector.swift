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
            snapshot.claude = localClaude
            let statuslineAccounts = collectClaudeStatuslineAccounts(localFallback: localClaude)
            let desktopAccounts = collectClaudeDesktopPlanAccounts(localFallback: localClaude)
            snapshot.claudeAccounts = statuslineAccounts.isEmpty ? desktopAccounts : statuslineAccounts
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
                    if let rateLimits = payload["rate_limits"] as? [String: Any] {
                        usage.primaryLimit = rateWindow(from: rateLimits["primary"] as? [String: Any])
                        usage.secondaryLimit = rateWindow(from: rateLimits["secondary"] as? [String: Any])
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
                usage.primaryLimit = claudeRateWindow(from: rateLimits["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
                usage.secondaryLimit = claudeRateWindow(from: rateLimits["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)
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

    private func collectClaudeDesktopPlanAccounts(localFallback: ProviderUsage) -> [ProviderUsage] {
        let file = homeURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("plan-usage-history.json")

        guard
            let object = readJSONObject(from: file),
            let samples = object["samples"] as? [[String: Any]]
        else {
            return []
        }

        var latestByOrg: [String: [String: Any]] = [:]
        var countsByOrg: [String: Int] = [:]
        var samplesByOrg: [String: [[String: Any]]] = [:]

        for sample in samples {
            let org = stringValue(sample["org"]) ?? "default"
            countsByOrg[org, default: 0] += 1
            samplesByOrg[org, default: []].append(sample)

            let timestamp = doubleValue(sample["t"]) ?? 0
            let currentTimestamp = doubleValue(latestByOrg[org]?["t"]) ?? 0
            if timestamp >= currentTimestamp {
                latestByOrg[org] = sample
            }
        }

        var accounts: [ProviderUsage] = []
        for (org, sample) in latestByOrg {
            guard let values = sample["u"] as? [String: Any] else { continue }
            let desktopResetTimes = claudeDesktopResetTimes()
            let fiveHourReset = desktopResetTimes.fiveHour
                ?? claudeDesktopFiveHourReset(fromHistory: samplesByOrg[org] ?? [])

            var usage = ProviderUsage(kind: .claude)
            usage.accountName = org == "default" ? "Desktop" : "Desktop \(org.prefix(6))"
            usage.sourceFiles = 1
            usage.events = countsByOrg[org] ?? 1
            usage.planType = "Claude Desktop"
            usage.latestEventAt = dateFromEpochMilliseconds(sample["t"])
            usage.statuslineCapturedAt = usage.latestEventAt
            usage.primaryLimit = RateWindow(
                usedPercent: doubleValue(values["fh"]),
                windowMinutes: 5 * 60,
                resetsAt: fiveHourReset
            )
            usage.secondaryLimit = RateWindow(
                usedPercent: doubleValue(values["sd"]),
                windowMinutes: 7 * 24 * 60,
                resetsAt: desktopResetTimes.sevenDay
            )

            if let capturedAt = usage.latestEventAt, now.timeIntervalSince(capturedAt) > 30 * 60 {
                usage.note = "Claude Desktop 用量資料來自 \(DateFormatters.reset.string(from: capturedAt))"
            } else {
                usage.note = "來源：Claude Desktop plan usage history"
            }

            accounts.append(usage)
        }

        accounts.sort {
            ($0.latestEventAt ?? .distantPast) > ($1.latestEventAt ?? .distantPast)
        }

        if accounts.count == 1, localFallback.events > 0 {
            accounts[0].accountName = "Desktop"
            accounts[0].today = localFallback.today
            accounts[0].rollingFiveHours = localFallback.rollingFiveHours
            accounts[0].dailyTotals = localFallback.dailyTotals
            accounts[0].sourceFiles += localFallback.sourceFiles
            accounts[0].events += localFallback.events
            accounts[0].latestModel = localFallback.latestModel
        } else if accounts.count > 1 {
            for index in accounts.indices {
                accounts[index].accountName = "Desktop \(index + 1)"
            }
        }

        return accounts
    }

    private func claudeDesktopResetTimes() -> (fiveHour: Date?, sevenDay: Date?) {
        let claudeRoot = homeURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)

        return (
            fiveHour: claudeDesktopFiveHourReset(under: claudeRoot),
            sevenDay: claudeDesktopSevenDayReset(under: claudeRoot)
        )
    }

    private func claudeDesktopFiveHourReset(fromHistory samples: [[String: Any]]) -> Date? {
        let points: [(date: Date, usedPercent: Double)] = samples.compactMap { sample in
            guard
                let date = dateFromEpochMilliseconds(sample["t"]),
                let values = sample["u"] as? [String: Any],
                let usedPercent = doubleValue(values["fh"])
            else {
                return nil
            }
            return (date: date, usedPercent: usedPercent)
        }
        .sorted { $0.date < $1.date }

        guard !points.isEmpty else { return nil }

        var latestResetStart: Date?
        var previousPoint: (date: Date, usedPercent: Double)?
        for point in points {
            if let previousPoint {
                let largeDrop = previousPoint.usedPercent - point.usedPercent >= 50
                let resetToLowUsage = previousPoint.usedPercent >= 50 && point.usedPercent <= 5
                if largeDrop || resetToLowUsage {
                    latestResetStart = point.date
                }
            }
            previousPoint = point
        }

        if let latestResetStart {
            let resetAt = latestResetStart.addingTimeInterval(5 * 60 * 60)
            if resetAt > now {
                return resetAt
            }
        }

        return nil
    }

    private func claudeDesktopFiveHourReset(under claudeRoot: URL) -> Date? {
        let blobRoot = claudeRoot
            .appendingPathComponent("IndexedDB", isDirectory: true)
            .appendingPathComponent("https_claude.ai_0.indexeddb.blob", isDirectory: true)

        let marker = Array("resetsAtN".utf8)
        var candidates: [Date] = []

        for file in regularFiles(under: blobRoot) {
            guard let data = try? Data(contentsOf: file), data.count > marker.count + 8 else { continue }
            let bytes = [UInt8](data)
            var index = 0
            while index + marker.count + 8 <= bytes.count {
                guard bytes[index..<(index + marker.count)].elementsEqual(marker) else {
                    index += 1
                    continue
                }

                let valueStart = index + marker.count
                let valueEnd = valueStart + 8
                let timestamp = littleEndianDouble(Array(bytes[valueStart..<valueEnd]))
                if let date = plausibleFutureDate(fromEpochSeconds: timestamp, maxHoursAhead: 6) {
                    candidates.append(date)
                }
                index = valueEnd
            }
        }

        return candidates.min()
    }

    private func claudeDesktopSevenDayReset(under claudeRoot: URL) -> Date? {
        let storageRoot = claudeRoot
            .appendingPathComponent("Session Storage", isDirectory: true)

        var candidates: [Date] = []
        for file in regularFiles(under: storageRoot) {
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            candidates.append(contentsOf: sevenDayResetDates(in: String(decoding: data, as: UTF8.self)))
            let withoutNulls = data.filter { $0 != 0 }
            candidates.append(contentsOf: sevenDayResetDates(in: String(decoding: withoutNulls, as: UTF8.self)))
            if let utf16 = String(data: data, encoding: .utf16LittleEndian) {
                candidates.append(contentsOf: sevenDayResetDates(in: utf16))
            }
        }

        return candidates
            .filter { $0 > now }
            .min()
    }

    private func sevenDayResetDates(in text: String) -> [Date] {
        let pattern = #""windowName"\s*:\s*"7d[^"]*"\s*,\s*"resetsAt"\s*:\s*([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: text),
                let timestamp = Double(text[range])
            else {
                return nil
            }
            return plausibleFutureDate(fromEpochSeconds: timestamp, maxHoursAhead: 10 * 24)
        }
    }

    private func regularFiles(under root: URL) -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var files: [URL] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            files.append(file)
        }
        return files
    }

    private func littleEndianDouble(_ bytes: [UInt8]) -> Double {
        guard bytes.count == 8 else { return 0 }
        let value = bytes.enumerated().reduce(UInt64(0)) { partial, item in
            partial | (UInt64(item.element) << UInt64(item.offset * 8))
        }
        return Double(bitPattern: value)
    }

    private func plausibleFutureDate(fromEpochSeconds timestamp: Double, maxHoursAhead: Double) -> Date? {
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        guard date > now else { return nil }
        guard date.timeIntervalSince(now) <= maxHoursAhead * 60 * 60 else { return nil }
        return date
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
        return RateWindow(
            usedPercent: doubleValue(dictionary["used_percent"]),
            windowMinutes: intValue(dictionary["window_minutes"]),
            resetsAt: reset > 0 ? Date(timeIntervalSince1970: TimeInterval(reset)) : nil
        )
    }

    private func claudeRateWindow(from dictionary: [String: Any]?, windowMinutes: Int) -> RateWindow? {
        guard let dictionary else { return nil }
        let reset = doubleValue(dictionary["resets_at"])
        let resetsAt = (reset ?? 0) > 0 ? Date(timeIntervalSince1970: reset ?? 0) : nil
        let isExpired = resetsAt.map { $0 <= now } ?? false
        let usedPercent = isExpired ? nil : doubleValue(dictionary["used_percentage"])

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
        let windows = [usage.primaryLimit, usage.secondaryLimit].compactMap { $0 }
        if windows.isEmpty {
            return "尚未收到 Claude Code 官方 rate_limits；送出一次訊息後更新"
        }

        if windows.allSatisfy({ $0.usedPercent == nil }) {
            return "Claude rate limit 資料已過期；打開該帳號的 Claude Code 後會更新"
        }

        guard let capturedAt = usage.statuslineCapturedAt else {
            return nil
        }

        if now.timeIntervalSince(capturedAt) > 30 * 60 {
            return "官方資料來自 \(DateFormatters.reset.string(from: capturedAt))，該帳號下一次回覆後會刷新"
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

    private func dateFromEpochMilliseconds(_ value: Any?) -> Date? {
        guard let timestamp = doubleValue(value), timestamp > 0 else { return nil }
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1000)
        }
        return Date(timeIntervalSince1970: timestamp)
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
