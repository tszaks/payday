import SwiftUI

/// One shift (one day), however many rows it took to log it — a merged
/// cash+credit night reads as a single row with both amounts in the
/// subtitle, not two separate list rows. Shared between Dashboard and
/// Period detail so both screens describe a night the same way.
struct ShiftDayRow: View {
    let day: Date
    let entries: [TipEntry]

    private var totalCents: Int {
        entries.reduce(0) { $0 + $1.amountCents }
    }

    private var subtitle: String {
        var parts: [String] = []
        let breakdown = TipBreakdown.total(of: entries)
        if breakdown.cashCents > 0, breakdown.creditCents > 0 {
            parts.append("Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))")
        } else {
            parts.append(entries.first?.kind.displayName ?? "")
        }
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
                    .lineLimit(1)
            }
            Spacer()
            Text(Money.string(fromCents: totalCents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(.vertical, 4)
    }
}
