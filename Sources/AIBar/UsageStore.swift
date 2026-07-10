import Foundation
import Combine
import SwiftUI

struct MenuBarStatusLine: Equatable {
    var symbolName: String
    var name: String
    var code: String
    var value: String

    var title: String {
        "\(name) \(value)"
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefreshAt = Date().addingTimeInterval(60)

    let preferences: DisplayPreferences

    private static let refreshInterval: TimeInterval = 60
    private var timer: Timer?
    private var preferenceCancellable: AnyCancellable?

    var menuBarSymbol: String {
        if let lowest = menuBarRemainingValues().min(), lowest <= 20 {
            return "exclamationmark.triangle.fill"
        }
        if snapshot.errors.isEmpty {
            return "chart.bar.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    var menuBarTitle: String {
        menuBarLines.map(\.title).joined(separator: " ")
    }

    var menuBarLines: [MenuBarStatusLine] {
        preferences.visibleKinds.map { kind in
            guard let remaining = menuBarRemainingValue(for: kind) else {
                return MenuBarStatusLine(symbolName: kind.symbol, name: kind.title, code: kind.menuBarCode, value: "--")
            }
            return MenuBarStatusLine(symbolName: kind.symbol, name: kind.title, code: kind.menuBarCode, value: "\(Int(remaining.rounded()))%")
        }
    }

    var visibleProviders: [ProviderUsage] {
        snapshot.providers(orderedBy: preferences.order, mode: preferences.mode)
    }

    // Provider card metrics, shared with UsagePopover so the window height and the
    // scrollable list stay in sync as the number of accounts grows.
    static let providerRowHeight: CGFloat = 76
    static let providerRowSpacing: CGFloat = 8

    /// Height of the (possibly scrolling) provider list: shows up to a cap of rows,
    /// beyond which the list scrolls. The cap is lower when an error panel is shown.
    static func providerListHeight(rowCount: Int, hasErrors: Bool) -> CGFloat {
        let cap = hasErrors ? 3 : 4
        let visibleRows = max(1, min(rowCount, cap))
        return CGFloat(visibleRows) * providerRowHeight
            + CGFloat(max(visibleRows - 1, 0)) * providerRowSpacing
    }

    static func providerListScrolls(rowCount: Int, hasErrors: Bool) -> Bool {
        rowCount > (hasErrors ? 3 : 4)
    }

    var popoverSize: CGSize {
        CGSize(width: 400, height: ceil(popoverContentHeight))
    }

    private var popoverContentHeight: CGFloat {
        let rowCount = max(visibleProviders.count, 1)
        let providerListHeight = Self.providerListHeight(
            rowCount: rowCount,
            hasErrors: !snapshot.errors.isEmpty
        )
        let controlsHeight: CGFloat = 41
        let footerHeight: CGFloat = 28
        let verticalPadding: CGFloat = 24
        let errorHeight: CGFloat = snapshot.errors.isEmpty ? 0 : min(86, 32 + CGFloat(snapshot.errors.count) * 17)
        let sectionCount = snapshot.errors.isEmpty ? 3 : 4
        let sectionSpacing = CGFloat(sectionCount - 1) * 9

        return verticalPadding + providerListHeight + controlsHeight + footerHeight + errorHeight + sectionSpacing
    }

    init(preferences: DisplayPreferences = .shared) {
        self.preferences = preferences
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        preferenceCancellable = preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let newSnapshot = await Task.detached(priority: .utility) {
            UsageCollector().collect()
        }.value
        snapshot = newSnapshot
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        isRefreshing = false
    }

    private func menuBarRemainingValues() -> [Double] {
        visibleProviders.compactMap(menuBarRemainingValue)
    }

    private func menuBarRemainingValue(for kind: ProviderKind) -> Double? {
        snapshot.providers
            .filter { $0.kind == kind }
            .compactMap(menuBarRemainingValue)
            .min()
    }

    private func menuBarRemainingValue(for usage: ProviderUsage) -> Double? {
        usage.primaryLimit?.remainingPercent ?? usage.secondaryLimit?.remainingPercent
    }
}
