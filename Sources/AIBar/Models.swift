import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var menuBarCode: String {
        switch self {
        case .codex: return "CX"
        case .claude: return "CL"
        }
    }

    var subtitle: String {
        switch self {
        case .codex: return "官方 rate limit 剩餘"
        case .claude: return "官方 statusline 剩餘"
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "terminal.fill"
        case .claude: return "sparkles"
        }
    }
}

struct TokenTotals: Equatable {
    var input: Int = 0
    var cachedInput: Int = 0
    var output: Int = 0
    var reasoningOutput: Int = 0

    var total: Int {
        input + output
    }

    var expandedTotal: Int {
        input + cachedInput + output + reasoningOutput
    }

    mutating func add(_ other: TokenTotals) {
        input += other.input
        cachedInput += other.cachedInput
        output += other.output
        reasoningOutput += other.reasoningOutput
    }
}

struct RateWindow: Equatable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?
    var isExpired = false

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return min(max(100 - usedPercent, 0), 100)
    }
}

struct ProviderUsage: Identifiable, Equatable {
    var id: String {
        if let accountName, !accountName.isEmpty {
            return "\(kind.rawValue)-\(accountName)"
        }
        return kind.rawValue
    }

    var kind: ProviderKind
    var accountName: String?
    /// Identity used to dedupe the same account across the statusline and cloud
    /// sources; aligns with the statusline account name derived from the config
    /// dir. Falls back to `accountName` when nil.
    var claudeMergeKey: String?
    var today = TokenTotals()
    var rollingFiveHours = TokenTotals()
    var dailyTotals: [Date: TokenTotals] = [:]
    var latestEventAt: Date?
    var events: Int = 0
    var sourceFiles: Int = 0
    var primaryLimit: RateWindow?
    var secondaryLimit: RateWindow?
    var planType: String?
    var latestModel: String?
    var liveContext: TokenTotals?
    var sessionCostUSD: Double?
    var statuslineCapturedAt: Date?
    var limitErrorAt: Date?
    var note: String?

    var weekTotal: TokenTotals {
        dailyTotals.values.reduce(TokenTotals()) { partial, totals in
            var next = partial
            next.add(totals)
            return next
        }
    }

    var displayTitle: String {
        guard kind == .claude, let accountName = displayAccountName else {
            return kind.title
        }
        return "\(kind.title) \(accountName)"
    }

    private var displayAccountName: String? {
        guard
            let rawAccountName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawAccountName.isEmpty,
            rawAccountName != "default"
        else {
            return nil
        }

        return rawAccountName
    }

    var displaySubtitle: String {
        if kind == .claude {
            if primaryLimit != nil || secondaryLimit != nil {
                return "官方 statusline 剩餘"
            }
            return "本機 token 用量"
        }
        return kind.subtitle
    }

    var hasOfficialLimits: Bool {
        primaryLimit != nil || secondaryLimit != nil
    }
}

struct UsageSnapshot: Equatable {
    var codex = ProviderUsage(kind: .codex)
    var claude = ProviderUsage(kind: .claude)
    var claudeAccounts: [ProviderUsage] = []
    var capturedAt = Date()
    var errors: [String] = []

    var providers: [ProviderUsage] {
        [codex] + (claudeAccounts.isEmpty ? [claude] : claudeAccounts)
    }
}
