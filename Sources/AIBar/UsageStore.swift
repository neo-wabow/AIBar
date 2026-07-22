import Foundation
import Combine
import Dispatch
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
    private var refreshTimer: DispatchSourceTimer?
    private var preferenceCancellable: AnyCancellable?
    // Holds the process in an "active" state so macOS App Nap does not suspend the
    // background refresh timer/network while this menu-bar-only (LSUIElement) app is idle.
    private var backgroundActivity: NSObjectProtocol?

    /// The placeholder snapshot has no live data yet. Keep it separate from a
    /// later refresh so the popover can make the first load unambiguous without
    /// hiding already-visible usage while it updates.
    @Published private(set) var hasCompletedInitialRefresh = false

    var isLoadingInitialSnapshot: Bool {
        isRefreshing && !hasCompletedInitialRefresh
    }

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
        if isLoadingInitialSnapshot {
            return [
                MenuBarStatusLine(
                    symbolName: "arrow.triangle.2.circlepath",
                    name: "AI",
                    code: "AI",
                    value: "讀取中"
                )
            ]
        }

        let providers = Array(visibleProviders.prefix(2))
        let codes = MenuBarCodeResolver.resolve(for: providers)

        return zip(providers, codes).map { provider, code in
            guard let remaining = menuBarRemainingValue(for: provider) else {
                return MenuBarStatusLine(
                    symbolName: provider.kind.symbol,
                    name: provider.displayTitle,
                    code: code,
                    value: "--"
                )
            }
            return MenuBarStatusLine(
                symbolName: provider.kind.symbol,
                name: provider.displayTitle,
                code: code,
                value: "\(Int(remaining.rounded()))%"
            )
        }
    }

    var visibleProviders: [ProviderUsage] {
        snapshot.orderedProviders(customOrder: preferences.providerOrder, mode: preferences.mode)
    }

    // Provider card metrics, shared with UsagePopover so the window height and the
    // scrollable list stay in sync as the number of accounts grows.
    static let providerRowHeight: CGFloat = 96
    static let providerRowSpacing: CGFloat = 8
    /// Extra height each per-model scoped row (e.g. Fable) adds to a card. Must stay
    /// in sync with `ProviderCard`'s own layout.
    static let scopedRowHeight: CGFloat = 29

    /// Rendered height of a single card, accounting for any per-model scoped rows.
    static func cardHeight(scopedCount: Int) -> CGFloat {
        providerRowHeight + CGFloat(scopedCount) * scopedRowHeight
    }

    /// Pixel budget for the list before it starts scrolling: the cap number of
    /// base-height rows. Cards taller than the base (Fable etc.) eat into it, so a
    /// couple of tall cards can trigger scrolling sooner than the raw account count.
    private static func providerListCap(hasErrors: Bool) -> CGFloat {
        let cap = hasErrors ? 3 : 4
        return CGFloat(cap) * providerRowHeight + CGFloat(cap - 1) * providerRowSpacing
    }

    private static func providerListContentHeight(cardHeights: [CGFloat]) -> CGFloat {
        let heights = cardHeights.isEmpty ? [providerRowHeight] : cardHeights
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * providerRowSpacing
    }

    /// Height of the (possibly scrolling) provider list. Uses each card's real
    /// height so tall cards aren't clipped, capped at the pixel budget above which
    /// the list scrolls.
    static func providerListHeight(cardHeights: [CGFloat], hasErrors: Bool) -> CGFloat {
        min(providerListContentHeight(cardHeights: cardHeights), providerListCap(hasErrors: hasErrors))
    }

    static func providerListScrolls(cardHeights: [CGFloat], hasErrors: Bool) -> Bool {
        providerListContentHeight(cardHeights: cardHeights) > providerListCap(hasErrors: hasErrors) + 0.5
    }

    var popoverSize: CGSize {
        CGSize(width: 400, height: ceil(popoverContentHeight))
    }

    /// Real rendered height of each visible provider card, in display order.
    var providerCardHeights: [CGFloat] {
        visibleProviders.map { Self.cardHeight(scopedCount: $0.scopedLimits.count) }
    }

    private var popoverContentHeight: CGFloat {
        let providerListHeight = Self.providerListHeight(
            cardHeights: providerCardHeights,
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

        // Prevent App Nap from freezing the periodic refresh while the app sits idle in
        // the menu bar. We still allow the system to sleep normally; on wake AppDelegate
        // triggers an immediate refresh.
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Periodic AI usage polling"
        )

        // A dispatch timer does not depend on the main RunLoop's current mode, which
        // makes periodic refreshes reliable while this menu-bar app sits idle.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.refreshInterval,
            repeating: Self.refreshInterval,
            leeway: .seconds(2)
        )
        timer.setEventHandler { [weak self] in
            Task { await self?.refresh() }
        }
        refreshTimer = timer
        timer.resume()

        preferenceCancellable = preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        refreshTimer?.setEventHandler {}
        refreshTimer?.cancel()
        if let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let newSnapshot = await Task.detached(priority: .utility) {
            UsageCollector().collect()
        }.value
        snapshot = newSnapshot
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        hasCompletedInitialRefresh = true
        isRefreshing = false
    }

    private func menuBarRemainingValues() -> [Double] {
        visibleProviders.compactMap(menuBarRemainingValue)
    }

    private func menuBarRemainingValue(for usage: ProviderUsage) -> Double? {
        // Prefer a live window: an expired window only carries a stale pre-reset
        // value ("待更新"), which shouldn't drive the menu bar's lowest-% readout.
        // Fall back to an expired value only when no live window is available.
        if let primary = usage.primaryLimit, !primary.isExpired { return primary.remainingPercent }
        if let secondary = usage.secondaryLimit, !secondary.isExpired { return secondary.remainingPercent }
        return usage.primaryLimit?.remainingPercent ?? usage.secondaryLimit?.remainingPercent
    }
}
