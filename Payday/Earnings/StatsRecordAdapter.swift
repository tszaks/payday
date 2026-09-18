import Foundation

/// Turns stored `ShiftRecord`s into the `TipRecord` rows `StatsEngine`
/// analyses: the second crossing from SwiftData into a value type, beside
/// `ShiftInputAdapter`.
///
/// It exists because `StatsEngine` has not moved into PaydayCore yet (the
/// plan's PR 5/PR 8 work), so Insights still needs row-shaped input while
/// every figure around it comes from the ledger. Without this, Insights is
/// the one screen that cannot be switched to the new representation at all,
/// and an unswitched Insights beside a switched Dashboard is two surfaces
/// disagreeing about the same fact — the thing the whole project exists to
/// end.
///
/// **Why a shift becomes up to two rows.** `TipRecord` carries one
/// `amountCents` and one `kind`, and Insights reads that split (cash versus
/// credit facts). So a record emits one row per kind it actually holds, both
/// sharing `shiftID = record.id`, which is how `StatsEngine` regroups them
/// into the single shift they came from. Shift-level values — hours, tip-out,
/// sales, period, clock times, receipt metrics — go on EXACTLY ONE of them,
/// the rule `TipRecord`'s own field comments state, because the engine sums
/// rows per shift and a value on both rows is a value counted twice.
@MainActor
enum StatsRecordAdapter {
    /// Newest-first is not imposed here; `StatsEngine` orders what it needs.
    static func tipRecords(from records: [ShiftRecord]) -> [TipRecord] {
        var out: [TipRecord] = []
        out.reserveCapacity(records.count * 2)
        for record in records {
            out.append(contentsOf: rows(for: record))
        }
        return out
    }

    /// One record's rows.
    private static func rows(for record: ShiftRecord) -> [TipRecord] {
        // The v2 fold, run through the ONE function allowed to stamp
        // `earningsSchemaVersion`, and run for a reason worth stating
        // precisely.
        //
        // `TipRecord.voluntaryTipCents` is
        // `metrics.voluntaryTipsCents(fromStoredAmount: amountCents)`, which
        // on a **v1** payload returns `max(0, amount - gratuity)` —
        // `employeeGratuityFeesCents` is NOT version-guarded, only
        // `separatedGratuityFeesCents` is. A `ShiftRecord`'s amounts are
        // already voluntary (`ShiftInputAdapter`: "ShiftRecord stores v2
        // earnings only, so the v1 gratuity fold already happened once, at
        // the deriver"), so handing a v1-stamped payload straight to
        // `TipRecord` would subtract the gratuity a SECOND time and leave
        // Insights lower than every other screen by exactly that amount.
        //
        // Routing through `normalizedToV2` removes the dependency on that
        // invariant instead of trusting it. The function is idempotent: on
        // the v2 metrics a record is supposed to carry it returns the
        // amounts and the payload untouched, so this is a no-op on all real
        // data. If the invariant were ever violated it folds ONCE and stamps
        // v2, converging on the same semantics the snapshot uses rather than
        // double-subtracting. Trusting the invariant silently is the shape of
        // bug this adapter is guarding against, so it does not.
        let cash: Int
        let credit: Int
        let metrics: ShiftReceiptMetrics?
        if let stored = record.receiptMetrics {
            // `.credit` is the owner `ShiftDetails.metricsOwner` and
            // `private.derive_shifts`' `metrics_rank` both pick. Two
            // spellings of the owner is a money difference, not a style
            // difference.
            let folded = ShiftReceiptMetrics.normalizedToV2(
                cashCents: record.cashTipsCents,
                creditCents: record.creditTipsCents,
                metrics: stored,
                owner: .credit
            )
            cash = folded.cash
            credit = folded.credit
            metrics = folded.metrics
        } else {
            cash = record.cashTipsCents
            credit = record.creditTipsCents
            metrics = nil
        }

        var rows: [TipRecord] = []
        // A wage-only or gratuity-only shift has zero tips of either kind and
        // still has to reach the engine: it carries hours, so dropping it
        // would silently remove it from every $/hr and every comparison.
        // Emitting the cash row unconditionally when both are zero is what
        // keeps the grouping total — `InsightsEarnings.pricing` refuses the
        // whole page if any engine shift is missing from the snapshot, so a
        // dropped row there is not a small error, it collapses Insights to
        // tips-only.
        let kinds: [(TipKind, Int)] = {
            var pairs: [(TipKind, Int)] = []
            if cash != 0 { pairs.append((.cash, cash)) }
            if credit != 0 { pairs.append((.credit, credit)) }
            return pairs.isEmpty ? [(.cash, 0)] : pairs
        }()

        for (index, pair) in kinds.enumerated() {
            let ownsShiftLevelValues = index == 0
            rows.append(TipRecord(
                date: record.workDate,
                amountCents: pair.1,
                kind: pair.0,
                // Vestigial in `TipRecord` and never read for logic: a
                // "double" is a day with 2+ distinct shiftIDs, which the
                // engine derives itself.
                isDouble: false,
                recordedAt: record.recordedAt,
                hoursWorked: ownsShiftLevelValues ? record.hoursWorked : nil,
                tipOutCents: ownsShiftLevelValues ? record.tipOutCents : nil,
                salesCents: ownsShiftLevelValues ? record.salesCents : nil,
                shiftPeriod: ownsShiftLevelValues ? record.shiftPeriod : nil,
                shiftID: record.id,
                clockIn: ownsShiftLevelValues ? record.clockIn : nil,
                clockOut: ownsShiftLevelValues ? record.clockOut : nil,
                serverCount: ownsShiftLevelValues ? record.serverCount : nil,
                receiptMetrics: ownsShiftLevelValues ? metrics : nil,
                note: ownsShiftLevelValues ? record.note : nil
            ))
        }
        return rows
    }
}
