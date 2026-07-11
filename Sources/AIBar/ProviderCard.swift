import SwiftUI

struct ProviderCard: View {
    let usage: ProviderUsage
    let accent: Color
    let showsDragHandle: Bool

    private var primaryRemaining: Double? { usage.primaryLimit?.remainingPercent }
    private var secondaryRemaining: Double? { usage.secondaryLimit?.remainingPercent }
    private var displayedRemaining: Double? { primaryRemaining ?? secondaryRemaining }

    /// A named Claude account (not the bare default) shows the account name/email
    /// instead of the provider name — the icon already signals the provider.
    private var isNamedAccount: Bool { usage.displayTitle != usage.kind.title }

    private var cardTitle: String {
        guard isNamedAccount, let accountName = usage.accountName, !accountName.isEmpty else {
            return usage.displayTitle
        }
        return accountName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            MeterRow(
                label: "5 小時",
                remaining: primaryRemaining,
                resetAt: usage.primaryLimit?.resetsAt,
                isExpired: usage.primaryLimit?.isExpired == true,
                accent: accent,
                unavailableText: unavailableText
            )

            MeterRow(
                label: "一週",
                remaining: secondaryRemaining,
                resetAt: usage.secondaryLimit?.resetsAt,
                isExpired: usage.secondaryLimit?.isExpired == true,
                accent: accent,
                unavailableText: unavailableText
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(limitColor(displayedRemaining).opacity((displayedRemaining ?? 100) <= 45 ? 0.35 : 0.10), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: usage.kind.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accent, in: Circle())

            Text(cardTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(usage.displayTitle)

            if let note = usage.note {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.tertiary)
                    .help(note)
            }

            Spacer(minLength: 4)

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.tertiary)
                    .help("拖曳調整順序")
            }
        }
    }

    private var unavailableText: String {
        usage.kind == .claude && !usage.hasOfficialLimits ? "未同步" : "重置 --"
    }

    private var cardBackground: Color {
        guard let remaining = displayedRemaining else { return AppColors.panel }
        if remaining <= 20 { return Color(red: 1.00, green: 0.94, blue: 0.93) }
        if remaining <= 45 { return Color(red: 1.00, green: 0.97, blue: 0.90) }
        return AppColors.panel
    }

    private func limitColor(_ value: Double?) -> Color {
        guard let value else { return AppColors.tertiary }
        if value <= 20 { return Color(red: 0.88, green: 0.18, blue: 0.16) }
        if value <= 45 { return Color(red: 0.92, green: 0.50, blue: 0.12) }
        return accent
    }
}

private struct MeterRow: View {
    let label: String
    let remaining: Double?
    let resetAt: Date?
    let isExpired: Bool
    let accent: Color
    let unavailableText: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.secondary)
                .frame(width: 42, alignment: .leading)

            UsageProgressBar(value: progressValue, fill: displayColor)
                .frame(height: 7)
                .frame(maxWidth: .infinity)

            Text(percentText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(displayColor)
                .frame(width: 46, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(resetText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColors.tertiary)
                .frame(width: 72, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .help(isExpired ? "此視窗已過重置時間,顯示的是重置前的最後數值;下次活動後更新" : "")
    }

    private var progressValue: Double {
        guard let remaining else { return 0 }
        return min(max(remaining / 100, 0), 1)
    }

    private var percentText: String {
        guard let remaining else { return "--" }
        return TokenFormat.percent(remaining)
    }

    private var resetText: String {
        if isExpired { return "待更新" }
        guard remaining != nil else { return unavailableText }
        guard let resetAt else { return "重置 --" }
        return "重置 \(DateFormatters.reset.string(from: resetAt))"
    }

    private var displayColor: Color {
        isExpired ? limitColor.opacity(0.45) : limitColor
    }

    private var limitColor: Color {
        guard let remaining else { return AppColors.tertiary }
        if remaining <= 20 { return Color(red: 0.88, green: 0.18, blue: 0.16) }
        if remaining <= 45 { return Color(red: 0.92, green: 0.50, blue: 0.12) }
        return accent
    }
}

private struct UsageProgressBar: View {
    let value: Double
    let fill: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColors.tile)
                if value > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(3, proxy.size.width * value))
                }
            }
        }
    }
}
