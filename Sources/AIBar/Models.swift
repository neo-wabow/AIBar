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

    var menuBarCode: String {
        guard kind == .claude, let accountName = displayAccountName else {
            return kind.menuBarCode
        }

        let localPart = accountName.split(separator: "@", maxSplits: 1).first.map(String.init) ?? accountName
        let shortName = String(localPart.prefix(6))
        return shortName.isEmpty ? kind.menuBarCode : shortName
    }

    var menuBarDisambiguationParts: (nameInitial: String, domain: String)? {
        guard kind == .claude, let accountName = displayAccountName else { return nil }

        let parts = accountName.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let localPart = String(parts[0])
        let domain = String(parts[1]).lowercased()
        guard
            !localPart.isEmpty,
            !domain.isEmpty,
            let initial = localPart.unicodeScalars.first(where: {
                $0.value < 128 && CharacterSet.alphanumerics.contains($0)
            })
        else {
            return nil
        }

        return (String(initial), domain)
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

    /// Stable identity for persisting the user's custom card order. Uses the merge
    /// key (config-dir-derived) so it survives the display label changing.
    var orderKey: String {
        switch kind {
        case .codex: return "codex"
        case .claude: return "claude:\(claudeMergeKey ?? accountName ?? "default")"
        }
    }
}

enum MenuBarCodeResolver {
    private static let maximumCodeLength = 6

    static func resolve(for providers: [ProviderUsage]) -> [String] {
        var codes = providers.map(\.menuBarCode)
        guard
            providers.count == 2,
            codes[0].caseInsensitiveCompare(codes[1]) == .orderedSame
        else {
            return codes
        }

        if
            providers.allSatisfy({ $0.kind == .claude }),
            let first = providers[0].menuBarDisambiguationParts,
            let second = providers[1].menuBarDisambiguationParts,
            let domainCodes = distinctDomainCodes(first: first, second: second)
        {
            return domainCodes
        }

        var claudeNumber = 0
        for index in providers.indices where providers[index].kind == .claude {
            claudeNumber += 1
            codes[index] = "CL\(claudeNumber)"
        }
        return codes
    }

    private static func distinctDomainCodes(
        first: (nameInitial: String, domain: String),
        second: (nameInitial: String, domain: String)
    ) -> [String]? {
        let fixedLength = max(first.nameInitial.count, second.nameInitial.count) + 1
        let maximumDomainLength = maximumCodeLength - fixedLength
        guard maximumDomainLength >= 1 else { return nil }

        for length in 1...maximumDomainLength {
            let firstCode = "\(first.nameInitial)@\(first.domain.prefix(length))"
            let secondCode = "\(second.nameInitial)@\(second.domain.prefix(length))"
            if firstCode.caseInsensitiveCompare(secondCode) != .orderedSame {
                return [firstCode, secondCode]
            }
        }

        return nil
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
