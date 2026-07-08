import SwiftUI

struct UsagePopover: View {
    @ObservedObject var store: UsageStore

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

            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(store.snapshot.providers) { provider in
                        ProviderCard(
                            usage: provider,
                            accent: provider.kind == .codex ? AppColors.codexAccent : AppColors.claudeAccent
                        )
                    }
                }

                footer

                if !store.snapshot.errors.isEmpty {
                    errorPanel
                }
            }
            .padding(12)
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            Task { await store.refresh() }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
            Text("下次更新 \(DateFormatters.timeWithSeconds.string(from: store.nextRefreshAt))")
                .lineLimit(1)

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("重新整理")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(AppColors.secondary)
    }

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("讀取時發生問題", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.70, green: 0.15, blue: 0.15))
            ForEach(store.snapshot.errors, id: \.self) { error in
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.red.opacity(0.18), lineWidth: 1)
        )
    }

}
