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

final class DisplayPreferences: ObservableObject {
    static let shared = DisplayPreferences()

    @Published var mode: ProviderDisplayMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    /// User's custom card order, as a list of `ProviderUsage.orderKey`s. Unknown
    /// (newly-appeared) providers sort after known ones, preserving their natural
    /// order until dragged.
    @Published var providerOrder: [String] {
        didSet {
            defaults.set(providerOrder, forKey: Self.orderKey)
        }
    }

    private static let modeKey = "display.mode"
    private static let orderKey = "display.providerOrder"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ProviderDisplayMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .all
        providerOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
    }

    /// Reorders `source` to sit just before `target`, using the currently displayed
    /// order as the basis, then persists the full order.
    func move(_ source: String, before target: String, in currentOrder: [String]) {
        guard source != target else { return }
        var order = currentOrder
        guard let from = order.firstIndex(of: source) else { return }
        order.remove(at: from)
        let insertAt = order.firstIndex(of: target) ?? order.count
        order.insert(source, at: insertAt)
        providerOrder = order
    }
}

extension UsageSnapshot {
    func orderedProviders(customOrder: [String], mode: ProviderDisplayMode) -> [ProviderUsage] {
        let all = ([codex] + (claudeAccounts.isEmpty ? [claude] : claudeAccounts))
            .filter { mode.includes($0.kind) }
        return all.enumerated().sorted { lhs, rhs in
            let li = customOrder.firstIndex(of: lhs.element.orderKey) ?? Int.max
            let ri = customOrder.firstIndex(of: rhs.element.orderKey) ?? Int.max
            if li != ri { return li < ri }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
