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
    @Published private(set) var nextRefreshAt = Date().addingTimeInterval(15)

    let preferences: DisplayPreferences

    private static let refreshInterval: TimeInterval = 15
    private var timer: Timer?
    private var preferenceCancellable: AnyCancellable?

    var menuBarSymbol: String {
        if let lowest = primaryRemainingValues().min(), lowest <= 20 {
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
            guard let remaining = primaryRemainingValue(for: kind) else {
                return MenuBarStatusLine(symbolName: kind.symbol, name: kind.title, code: kind.menuBarCode, value: "--")
            }
            return MenuBarStatusLine(symbolName: kind.symbol, name: kind.title, code: kind.menuBarCode, value: "\(Int(remaining.rounded()))%")
        }
    }

    var visibleProviders: [ProviderUsage] {
        snapshot.providers(orderedBy: preferences.order, mode: preferences.mode)
    }

    var popoverSize: CGSize {
        CGSize(width: 400, height: ceil(popoverContentHeight))
    }

    private var popoverContentHeight: CGFloat {
        let rowCount = max(visibleProviders.count, 1)
        let rowGaps = max(rowCount - 1, 0)
        let fullProviderListHeight = CGFloat(rowCount) * 76 + CGFloat(rowGaps) * 8
        let providerListHeight = min(fullProviderListHeight, snapshot.errors.isEmpty ? 160 : 112)
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

    private func primaryRemainingValues() -> [Double] {
        visibleProviders.compactMap { $0.primaryLimit?.remainingPercent }
    }

    private func primaryRemainingValue(for kind: ProviderKind) -> Double? {
        snapshot.providers
            .filter { $0.kind == kind }
            .compactMap { $0.primaryLimit?.remainingPercent }
            .min()
    }
}
