import SwiftUI

struct UsagePopover: View {
    @ObservedObject var store: UsageStore

    private let providerRowHeight: CGFloat = 76
    private let providerRowSpacing: CGFloat = 8

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
                ScrollView(.vertical, showsIndicators: store.snapshot.providers.count > 2) {
                    VStack(spacing: providerRowSpacing) {
                        ForEach(store.snapshot.providers) { provider in
                            ProviderCard(
                                usage: provider,
                                accent: provider.kind == .codex ? AppColors.codexAccent : AppColors.claudeAccent
                            )
                        }
                    }
                }
                .frame(height: providerListHeight)

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
        let count = max(store.snapshot.providers.count, 1)
        let fullHeight = CGFloat(count) * providerRowHeight + CGFloat(count - 1) * providerRowSpacing
        let maxHeight: CGFloat = store.snapshot.errors.isEmpty ? 160 : 112
        return min(fullHeight, maxHeight)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
            Text("下次更新 \(DateFormatters.timeWithSeconds.string(from: store.nextRefreshAt))")
                .lineLimit(1)

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("重新整理")
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

}
