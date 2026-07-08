import SwiftUI

struct ProviderCard: View {
    let usage: ProviderUsage
    let accent: Color

    private var primaryRemaining: Double? {
        usage.primaryLimit?.remainingPercent
    }

    private var secondaryRemaining: Double? {
        usage.secondaryLimit?.remainingPercent
    }

    private var secondaryTitle: String {
        usage.kind == .codex ? "1 週" : "7 天"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(usage.displayTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text("剩餘用量")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.secondary)
            }
            .frame(width: 126, alignment: .leading)

            Spacer(minLength: 0)

            RemainingColumn(
                title: "5 小時",
                remaining: primaryRemaining,
                resetAt: usage.primaryLimit?.resetsAt,
                accent: accent,
                isPrimary: true
            )
            .frame(width: 92, alignment: .trailing)

            RemainingColumn(
                title: secondaryTitle,
                remaining: secondaryRemaining,
                resetAt: usage.secondaryLimit?.resetsAt,
                accent: accent,
                isPrimary: false
            )
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(limitColor(primaryRemaining).opacity((primaryRemaining ?? 100) <= 45 ? 0.35 : 0.12), lineWidth: 1)
        )
    }

    private var cardBackground: Color {
        guard let remaining = primaryRemaining else {
            return AppColors.panel
        }
        if remaining <= 20 {
            return Color(red: 1.00, green: 0.94, blue: 0.93)
        }
        if remaining <= 45 {
            return Color(red: 1.00, green: 0.97, blue: 0.90)
        }
        return AppColors.panel
    }

    private func limitColor(_ value: Double?) -> Color {
        guard let value else { return AppColors.tertiary }
        if value <= 20 {
            return Color(red: 0.88, green: 0.18, blue: 0.16)
        }
        if value <= 45 {
            return Color(red: 0.92, green: 0.50, blue: 0.12)
        }
        return accent
    }
}

private struct RemainingColumn: View {
    let title: String
    let remaining: Double?
    let resetAt: Date?
    let accent: Color
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.secondary)

            Text(percentText)
                .font(.system(size: isPrimary ? 36 : 28, weight: .semibold, design: .rounded))
                .foregroundStyle(limitColor)
                .lineLimit(1)
                .minimumScaleFactor(0.70)

            Text(resetText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
    }

    private var percentText: String {
        guard let remaining else { return "--" }
        return TokenFormat.percent(remaining)
    }

    private var resetText: String {
        guard let resetAt else { return "重置 --" }
        return "重置 \(DateFormatters.reset.string(from: resetAt))"
    }

    private var limitColor: Color {
        guard let remaining else { return AppColors.tertiary }
        if remaining <= 20 {
            return Color(red: 0.88, green: 0.18, blue: 0.16)
        }
        if remaining <= 45 {
            return Color(red: 0.92, green: 0.50, blue: 0.12)
        }
        return accent
    }
}
