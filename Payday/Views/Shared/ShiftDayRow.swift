import SwiftUI

/// One shift (one closeout), however many rows it took to log it — a merged
/// cash+credit shift reads as a single row: date/period label on the left,
/// Total on the right, nothing else. Shared between Dashboard and Period
/// detail so both screens describe a shift the same way. Every row uses the
/// same "Tuesday, Aug 25 · Dinner" shape so recency and
/// double-shift status never change what the label reveals. No money caption
/// underneath the label — cash and credit are a decomposition, and showing
/// their gross figures next to this row's net Total would visibly fail to sum
/// (Tyler's money-language
/// law, 2026-07-27: at most one money line per row, and it's the Total). The
/// split is one tap away in the shift's own sheet, and the period-level
/// drawer carries it too.
struct ShiftDayRow: View {
    let day: Date
    let period: ShiftPeriod?
    let dayHasMultipleShifts: Bool
    let entries: [TipEntry]
    /// This shift's wages, already valued by the ledger as its slice of the
    /// workweek allocation — `WageEstimate.centsByShiftID` over the SAME
    /// shift grouping this list renders, so the sum of the rows is the total
    /// above them by construction rather than by coincidence.
    ///
    /// Deliberately not a rate. The row used to take `wageCentsPerHour` and
    /// do its own `rate x hours` rounding, which made a day's two rows come
    /// to 2760c under a 2759c hero (PR 3 review, P0). It cannot compute this
    /// alone: overtime and the cumulative rounding are properties of the
    /// whole workweek, not of one shift. 0 when the wage feature is off or
    /// the shift logged no hours, which is how the row has always read.
    var wageCents: Int = 0
    /// The shift's own note, shown as a quiet caption under the label.
    ///
    /// Opt-in and nil by default so Dashboard is unchanged. The
    /// one-money-line law above bans a MONEY caption here, because cash and
    /// credit are a decomposition that would visibly fail to sum against
    /// the Total. A note is not money and does not have that problem.
    ///
    /// It exists because the note was otherwise undiscoverable: it has
    /// always been editable inside the shift's own sheet, but nothing on a
    /// list ever hinted one was there. It used to surface on Insights as a
    /// DATA NOTE, which put a caveat about one August shift at the bottom
    /// of a page about next week.
    var note: String? = nil

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: entries)
    }

    /// Net tips plus this shift's wages. Sums to the hero above it exactly:
    /// both are the same `WageEstimate.centsPerShift` array.
    private var netCents: Int {
        breakdown.netTotalCents + wageCents
    }

    private var trimmedNote: String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShiftDays.shiftLabel(day: day, period: period, dayHasMultipleShifts: dayHasMultipleShifts))
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                if let trimmedNote {
                    Text(trimmedNote)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: PaydaySpacing.p12)
            Text(Money.string(fromCents: netCents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(.vertical, 4)
    }
}
