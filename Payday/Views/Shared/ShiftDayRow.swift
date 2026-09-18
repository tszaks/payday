import SwiftUI

/// Everything one shift row shows, and nothing it computes.
///
/// The wave-0 worked example of the PR 5 adapter contract
/// (`Payday/Earnings/SnapshotFacts.swift`): presentation on the left, ONE
/// `EarningsFigure` from the engine on the right, and no arithmetic anywhere
/// between them.
///
/// The row used to take `wageCentsPerHour` and do its own `rate × hours`. PR 3
/// took the rate away and gave it `wageCents`, an `Int` the caller had already
/// asked the ledger for. PR 5 takes the loose `Int` away too: an `Int` has no
/// completeness, so a row holding one could not tell "this shift earned
/// nothing" from "Payday has no idea what this shift earned", and both
/// rendered as `$0.00`. A `ShiftValuation` knows the difference and an absent
/// one is `.unavailable`.
struct ShiftDayRowFacts: Equatable, SnapshotFacts {
    // MARK: Presentation

    let day: Date
    let period: ShiftPeriod?
    let dayHasMultipleShifts: Bool
    /// The shift's own note, shown as a quiet caption under the label.
    ///
    /// Opt-in and nil by default so Dashboard is unchanged. Tyler's
    /// money-language law (2026-07-27) bans a MONEY caption here, because
    /// cash and credit are a decomposition that would visibly fail to sum
    /// against the row's own figure. A note is not money and does not have
    /// that problem.
    let note: String?

    // MARK: Money, from the engine

    /// This shift's earnings, wage-inclusive, as the ledger valued it: its
    /// slice of the WORKWEEK allocation, carrying its share of overtime and
    /// of the cumulative rounding.
    ///
    /// A row cannot compute this and must not try. Overtime and the
    /// cumulative rounding are properties of the whole workweek, not of one
    /// shift, which is why W1's two shifts are 1203 and 1556 — summing to
    /// the week's 2759 — and not the 1203 and 1557 that independent
    /// per-shift rounding produces and that made a day's rows come to 2760
    /// under a 2759 hero (PR 3 review, P0).
    let amount: EarningsFigure

    let stamp: SnapshotStamp?

    // MARK: Construction

    /// The wave-1 spelling: the snapshot plus the id of the shift this row
    /// renders. An id the snapshot does not hold renders as unavailable, not
    /// as zero.
    init(
        snapshot: EarningsSnapshot?,
        shiftID: UUID,
        day: Date,
        period: ShiftPeriod?,
        dayHasMultipleShifts: Bool,
        note: String? = nil
    ) {
        self.init(
            valuation: snapshot?.valuation(shiftID),
            wageFeatureEnabled: snapshot?.wageFeatureEnabled ?? false,
            stamp: snapshot?.stamp,
            day: day,
            period: period,
            dayHasMultipleShifts: dayHasMultipleShifts,
            note: note
        )
    }

    /// For a caller that already holds the valuation, which is every caller
    /// rendering a LIST: the list asks the snapshot once and hands each row
    /// its own valuation, rather than each row re-querying.
    init(
        valuation: ShiftValuation?,
        wageFeatureEnabled: Bool,
        stamp: SnapshotStamp?,
        day: Date,
        period: ShiftPeriod?,
        dayHasMultipleShifts: Bool,
        note: String? = nil
    ) {
        self.day = day
        self.period = period
        self.dayHasMultipleShifts = dayHasMultipleShifts
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.amount = EarningsFigure.shiftEarnedIncome(
            valuation,
            wageFeatureEnabled: wageFeatureEnabled
        )
        self.stamp = stamp
    }

    var label: String {
        ShiftDays.shiftLabel(
            day: day,
            period: period,
            dayHasMultipleShifts: dayHasMultipleShifts
        )
    }
}

/// One shift (one closeout), however many rows it took to log it — a merged
/// cash+credit shift reads as a single row: date/period label on the left,
/// the shift's own figure on the right, nothing else. Shared between
/// Dashboard, the day sheet and Period detail so all three describe a shift
/// the same way. Every row uses the same "Tuesday, Aug 25 · Dinner" shape so
/// recency and double-shift status never change what the label reveals.
///
/// No money caption underneath the label — cash and credit are a
/// decomposition, and showing their gross figures next to this row's net
/// figure would visibly fail to sum (Tyler's money-language law, 2026-07-27:
/// at most one money line per row). The split is one tap away in the shift's
/// own sheet, and the period-level drawer carries it too.
struct ShiftDayRow: View {
    let facts: ShiftDayRowFacts

    /// What stands in for an amount the engine could not produce.
    ///
    /// Not "$0.00", which would be a sentence about money that is not true,
    /// and not blank, which reads as a layout bug. An en dash is the
    /// platform's own "no value here".
    static let unavailablePlaceholder = "–"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(facts.label)
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                if let note = facts.note {
                    Text(note)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: PaydaySpacing.p12)
            Text(facts.amount.text ?? Self.unavailablePlaceholder)
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(
                    facts.amount.isUnavailable ? PaydayColor.textSecondary : PaydayColor.textPrimary
                )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// VoiceOver reads the label, then the figure — or, when there is no
    /// figure, says so in words instead of reading a dash.
    private var accessibilityLabel: String {
        guard let amount = facts.amount.text else {
            return "\(facts.label). Amount unavailable."
        }
        return "\(facts.label). \(amount)"
    }
}
