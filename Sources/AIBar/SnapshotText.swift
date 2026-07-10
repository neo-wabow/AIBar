import Foundation

enum SnapshotText {
    static func render(_ snapshot: UsageSnapshot) -> String {
        var lines: [String] = []
        lines.append("AIBar snapshot \(DateFormatters.reset.string(from: snapshot.capturedAt))")
        lines.append(contentsOf: snapshot.providers.map(renderProvider))
        if !snapshot.errors.isEmpty {
            lines.append("Errors:")
            lines.append(contentsOf: snapshot.errors.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func renderProvider(_ usage: ProviderUsage) -> String {
        let total = usage.kind == .claude ? usage.today.expandedTotal : usage.today.total
        let rolling = usage.kind == .claude ? usage.rollingFiveHours.expandedTotal : usage.rollingFiveHours.total
        var parts: [String] = [
            "\(usage.displayTitle): today=\(TokenFormat.full(total))",
            "5h=\(TokenFormat.full(rolling))",
            "events=\(usage.events)",
            "files=\(usage.sourceFiles)"
        ]
        if let context = usage.liveContext {
            parts.append("live_context=\(TokenFormat.full(context.expandedTotal))")
        }
        if let cost = usage.sessionCostUSD {
            parts.append("session_cost=\(CostFormat.usd(cost))")
        }
        if let primary = usage.primaryLimit {
            parts.append("primary_remaining=\(TokenFormat.percent(primary.remainingPercent))")
            parts.append("primary_used=\(TokenFormat.percent(primary.usedPercent))")
            if let reset = primary.resetsAt {
                parts.append("primary_reset=\(DateFormatters.reset.string(from: reset))")
            }
            if primary.isExpired {
                parts.append("primary_expired=true")
            }
        }
        if let secondary = usage.secondaryLimit {
            parts.append("secondary_remaining=\(TokenFormat.percent(secondary.remainingPercent))")
            parts.append("secondary_used=\(TokenFormat.percent(secondary.usedPercent))")
            if let reset = secondary.resetsAt {
                parts.append("secondary_reset=\(DateFormatters.reset.string(from: reset))")
            }
            if secondary.isExpired {
                parts.append("secondary_expired=true")
            }
        }
        if let latestModel = usage.latestModel {
            parts.append("model=\(latestModel)")
        }
        if let note = usage.note {
            parts.append("note=\(note)")
        }
        return parts.joined(separator: " ")
    }
}
