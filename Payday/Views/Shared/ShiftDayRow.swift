import SwiftUI

/// One shift (one day), however many rows it took to log it — a merged
/// cash+credit night reads as a single row with both amounts in the
/// subtitle, not two separate list rows. Shared between Dashboard and
/// Period detail so both screens describe a night the same way.
struct ShiftDayRow: View {
    let day: Date
    let entries: [TipEntry]

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: entries)
    }

    /// Net — the income number. Matches the hero total and the tonight
    /// reveal, which are both net, so one shift never shows two numbers.
    private var netCents: Int {
        breakdown.netTotalCents
    }

    private var subtitle: String {
        var parts: [String] = []
        if breakdown.cashCents > 0, breakdown.creditCents > 0 {
            parts.append("Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))")
        } else {
            parts.append(entries.first?.kind.displayName ?? "")
        }
        // Tip-out is deliberately not shown per-row: the amount to the right
        // is already net (what you kept), and a tip-out isn't income worth
        // repeating on every glance. It stays visible/editable in the shift's
        // own sheet, and the period hero still reconciles it.
        if entries.contains(where: \.isDouble) {
            parts.append("double")
        }
        if let note = entries.compactMap(\.note).first(where: { !$0.isEmpty }) {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShiftDays.humanLabel(for: day))
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                Text(subtitle)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(Money.string(fromCents: netCents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(.vertical, 4)
    }
}
