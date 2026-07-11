import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    var onManageAccounts: () -> Void = {}
    @State private var draggedKind: ProviderKind?

    private let providerRowSpacing = UsageStore.providerRowSpacing

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppColors.backgroundTop,
                    AppColors.backgroundBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 9) {
                ScrollView(.vertical, showsIndicators: listScrolls) {
                    VStack(spacing: providerRowSpacing) {
                        ForEach(store.visibleProviders) { provider in
                            providerCard(for: provider)
                        }
                    }
                }
                .frame(height: providerListHeight)

                displayControls

                footer

                if !store.snapshot.errors.isEmpty {
                    errorPanel
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            Task { await store.refresh() }
        }
    }

    private var providerListHeight: CGFloat {
        UsageStore.providerListHeight(
            rowCount: max(store.visibleProviders.count, 1),
            hasErrors: !store.snapshot.errors.isEmpty
        )
    }

    private var listScrolls: Bool {
        UsageStore.providerListScrolls(
            rowCount: store.visibleProviders.count,
            hasErrors: !store.snapshot.errors.isEmpty
        )
    }

    private var displayControls: some View {
        HStack(spacing: 10) {
            Text("顯示")
                .frame(width: 34, alignment: .leading)
            Picker("顯示", selection: displayModeBinding) {
                ForEach(ProviderDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AppColors.secondary)
        .controlSize(.small)
        .padding(.top, 7)
    }

    private var displayModeBinding: Binding<ProviderDisplayMode> {
        Binding(
            get: { store.preferences.mode },
            set: { store.preferences.mode = $0 }
        )
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("重新整理")

            Text("下次更新 \(DateFormatters.timeWithSeconds.string(from: store.nextRefreshAt))")
                .lineLimit(1)

            Spacer()

            Button {
                onManageAccounts()
            } label: {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("管理 Claude 帳號")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("離開 AIBar")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(AppColors.secondary)
    }

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("讀取時發生問題", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.70, green: 0.15, blue: 0.15))
            ForEach(store.snapshot.errors, id: \.self) { error in
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.red.opacity(0.18), lineWidth: 1)
        )
    }

    private var claudeAccountCount: Int {
        store.visibleProviders.filter { $0.kind == .claude }.count
    }

    private var canReorderProviders: Bool {
        store.preferences.mode == .all
            && store.visibleProviders.contains { $0.kind == .codex }
            && store.visibleProviders.contains { $0.kind == .claude }
    }

    @ViewBuilder
    private func providerCard(for provider: ProviderUsage) -> some View {
        let card = ProviderCard(
            usage: provider,
            accent: provider.kind == .codex ? AppColors.codexAccent : AppColors.claudeAccent,
            showsDragHandle: canReorderProviders,
            showsAccountName: provider.kind == .claude && claudeAccountCount >= 2
        )

        if canReorderProviders {
            card
                .onDrag {
                    draggedKind = provider.kind
                    return NSItemProvider(object: provider.kind.rawValue as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: ProviderReorderDropDelegate(
                        targetKind: provider.kind,
                        draggedKind: $draggedKind,
                        preferences: store.preferences
                    )
                )
        } else {
            card
        }
    }

}

private struct ProviderReorderDropDelegate: DropDelegate {
    let targetKind: ProviderKind
    @Binding var draggedKind: ProviderKind?
    let preferences: DisplayPreferences

    func validateDrop(info: DropInfo) -> Bool {
        guard preferences.mode == .all, let draggedKind else { return false }
        return draggedKind != targetKind
    }

    func dropEntered(info: DropInfo) {
        guard preferences.mode == .all, let draggedKind, draggedKind != targetKind else { return }
        preferences.move(draggedKind, before: targetKind)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedKind = nil
        return true
    }
}
