import SwiftUI

struct ProviderCard: View {
    let usage: ProviderUsage
    let accent: Color
    let showsDragHandle: Bool

    private var primaryRemaining: Double? {
        usage.primaryLimit?.remainingPercent
    }

    private var secondaryRemaining: Double? {
        usage.secondaryLimit?.remainingPercent
    }

    private var secondaryTitle: String {
        "一週"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: usage.kind.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(usage.displayTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            .frame(width: 112, alignment: .leading)

            Spacer(minLength: 0)

            RemainingStrip(
                title: "5 小時",
                remaining: primaryRemaining,
                resetAt: usage.primaryLimit?.resetsAt,
                accent: accent
            )
            .frame(width: stripWidth)

            RemainingStrip(
                title: secondaryTitle,
                remaining: secondaryRemaining,
                resetAt: usage.secondaryLimit?.resetsAt,
                accent: accent
            )
            .frame(width: stripWidth)

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.tertiary)
                    .frame(width: 12, height: 34)
                    .help("拖曳調整順序")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(limitColor(primaryRemaining).opacity((primaryRemaining ?? 100) <= 45 ? 0.35 : 0.12), lineWidth: 1)
        )
    }

    private var stripWidth: CGFloat {
        showsDragHandle ? 96 : 104
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

private struct RemainingStrip: View {
    let title: String
    let remaining: Double?
    let resetAt: Date?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(percentText)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(limitColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }

            UsageProgressBar(value: progressValue, fill: limitColor)
                .frame(height: 6)

            Text(resetText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
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

private struct UsageProgressBar: View {
    let value: Double
    let fill: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.tile)

                if value > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(2, proxy.size.width * value))
                }
            }
        }
    }
}
