import Foundation
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

    private static let refreshInterval: TimeInterval = 15
    private var timer: Timer?

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
        ProviderKind.allCases.map { kind in
            guard let remaining = primaryRemainingValue(for: kind) else {
                return MenuBarStatusLine(symbolName: kind.symbol, name: kind.title, code: kind.menuBarCode, value: "--")
            }
            return MenuBarStatusLine(symbolName: kind.symbol, name: kind.title, code: kind.menuBarCode, value: "\(Int(remaining.rounded()))%")
        }
    }

    init() {
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
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
        snapshot.providers.compactMap { $0.primaryLimit?.remainingPercent }
    }

    private func primaryRemainingValue(for kind: ProviderKind) -> Double? {
        snapshot.providers
            .filter { $0.kind == kind }
            .compactMap { $0.primaryLimit?.remainingPercent }
            .min()
    }
}
