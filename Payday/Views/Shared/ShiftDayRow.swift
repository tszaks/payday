import SwiftUI

/// One shift (one closeout), however many rows it took to log it — a merged
/// cash+credit shift reads as a single row with both amounts in the
/// subtitle, not two separate list rows. Shared between Dashboard and
/// Period detail so both screens describe a shift the same way. On a double
/// day the two shifts each get their own row, distinguished by period
/// ("Today · Lunch" / "Today · Dinner").
struct ShiftDayRow: View {
    let day: Date
    let period: ShiftPeriod?
    let dayHasMultipleShifts: Bool
    let entries: [TipEntry]
    /// Base hourly rate, when the person has one set — folds this shift's
    /// wages (rate x its canonical hours, never OT) into the trailing
    /// amount. Nil means the wage feature is off; the row then reads exactly
    /// as it always has.
    var wageCentsPerHour: Int?

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: entries)
    }

    /// This shift's base-rate wages, from its one canonical hoursWorked
    /// value (ShiftDetails.resolve) — never per-entry, never OT.
    private var wageCents: Int {
        let hoursWorked = ShiftDetails.resolve(from: entries).hoursWorked ?? 0
        return WageEstimate.cents(wageCentsPerHour: wageCentsPerHour, hours: hoursWorked) ?? 0
    }

    /// Net tips plus this shift's wages — matches the hero total, the
    /// sheet's own total, and every other shift/day surface in the app.
    private var netCents: Int {
        breakdown.netTotalCents + wageCents
    }

    private var subtitle: String {
        var parts: [String] = []
        if breakdown.cashCents > 0, breakdown.creditCents > 0 {
            parts.append("Cash \(Money.string(fromCents: breakdown.cashCents)) · Credit \(Money.string(fromCents: breakdown.creditCents))")
        } else if breakdown.creditCents > 0 {
            parts.append("Credit \(Money.string(fromCents: breakdown.creditCents))")
        } else if breakdown.cashCents > 0 {
            parts.append("Cash \(Money.string(fromCents: breakdown.cashCents))")
        } else {
            parts.append(entries.first?.kind.displayName ?? "")
        }
        // Tip-out is deliberately not shown per-row: the amount to the right
        // is already net (what you kept), and a tip-out isn't income worth
        // repeating on every glance. It stays visible/editable in the shift's
        // own sheet, and the period hero still reconciles it.
        // Notes stay off list rows on purpose — they live in the shift's own sheet.
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShiftDays.shiftLabel(day: day, period: period, dayHasMultipleShifts: dayHasMultipleShifts))
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
