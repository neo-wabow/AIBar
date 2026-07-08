import Combine
import Foundation

enum ProviderDisplayMode: String, CaseIterable, Identifiable {
    case all
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    func includes(_ kind: ProviderKind) -> Bool {
        switch self {
        case .all:
            return true
        case .codex:
            return kind == .codex
        case .claude:
            return kind == .claude
        }
    }
}

enum ProviderDisplayOrder: String, CaseIterable, Identifiable {
    case codexFirst
    case claudeFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexFirst: return "Codex 上"
        case .claudeFirst: return "Claude 上"
        }
    }

    var orderedKinds: [ProviderKind] {
        switch self {
        case .codexFirst:
            return [.codex, .claude]
        case .claudeFirst:
            return [.claude, .codex]
        }
    }
}

final class DisplayPreferences: ObservableObject {
    static let shared = DisplayPreferences()

    @Published var mode: ProviderDisplayMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    @Published var order: ProviderDisplayOrder {
        didSet {
            defaults.set(order.rawValue, forKey: Self.orderKey)
        }
    }

    private static let modeKey = "display.mode"
    private static let orderKey = "display.order"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ProviderDisplayMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .all
        order = ProviderDisplayOrder(rawValue: defaults.string(forKey: Self.orderKey) ?? "") ?? .codexFirst
    }

    var visibleKinds: [ProviderKind] {
        order.orderedKinds.filter { mode.includes($0) }
    }

    func move(_ source: ProviderKind, before target: ProviderKind) {
        guard source != target else { return }
        order = source == .codex ? .codexFirst : .claudeFirst
    }
}

extension UsageSnapshot {
    func providers(orderedBy order: ProviderDisplayOrder, mode: ProviderDisplayMode) -> [ProviderUsage] {
        let groupedProviders: [ProviderKind: [ProviderUsage]] = [
            .codex: [codex],
            .claude: claudeAccounts.isEmpty ? [claude] : claudeAccounts
        ]

        return order.orderedKinds
            .filter { mode.includes($0) }
            .flatMap { groupedProviders[$0] ?? [] }
    }
}
