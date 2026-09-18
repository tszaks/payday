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
    /// **The one entry point.** Both representations in, one row list out.
    ///
    /// Same shape as the combined earnings builders, and for the same reason:
    /// `InsightsEarnings` and the widget's pace baseline both feed a
    /// `StatsEngine`, and a caller that picks its own representation is a
    /// caller that can forget to. The widget DID forget -- it fetched
    /// `TipEntry` directly, so post-flip its pace delta would have compared
    /// against a history that silently lost every post-conversion shift.
    static func tipRecords(
        entries: [TipEntry],
        records: [ShiftRecord],
        representation: ShiftRepresentation = .automatic
    ) -> [TipRecord] {
        representation.usesRecords
            ? tipRecords(from: records)
            : entries.map(TipRecord.init)
    }

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
        // Read RAW, deliberately, and this is a retraction of what this
        // function did when it was written.
        //
        // The first version routed cash/credit/metrics through
        // `ShiftReceiptMetrics.normalizedToV2` to avoid folding a v1 gratuity
        // twice, reasoning that `employeeGratuityFeesCents` is not
        // version-guarded while `voluntaryTipsCents(fromStoredAmount:)` is.
        // The reasoning about those two functions is correct. The conclusion
        // was wrong, for two reasons.
        //
        // **A v1 payload cannot reach a `ShiftRecord`**, and it is worth
        // being exact about what enforces that in a SHIPPED build:
        //
        // 1. On the server, unconditionally. `derive_shifts`' sanitizer does
        //    `jsonb_set(..., '{earningsSchemaVersion}', '2'::jsonb, true)`
        //    with `create_missing = true`, so every derived payload is v2
        //    whether or not the legacy row said so.
        // 2. On device, by `design-lint`, NOT by the assert. The
        //    `receiptMetrics` setter does `assert((version ?? 2) >= 2)`, and
        //    Swift compiles `assert` OUT under `-O` -- so that check holds in
        //    Debug and vanishes in Release. What actually enforces it in a
        //    shipped build is the lint rule failing the build on
        //    `.receiptMetrics =` outside `ShiftRecord.swift`, which makes
        //    `applyEarnings` the only writer and it folds through
        //    `normalizedToV2` before assigning. That is compile-time and
        //    always on. The assert is a Debug convenience, not the guarantee.
        //
        // Not "hardened" to `precondition`, deliberately: that would crash a
        // shipped build on a payload it can already read correctly, which is
        // a worse outcome than the one being guarded against.
        //
        // So the fold was a no-op on every reachable record. That alone would
        // make it harmless dead code; the second reason is why it had to go --
        // and note the second reason does NOT depend on reachability at all.
        // The measurement above only told us WHICH of the two readers to
        // change.
        //
        // **`ShiftRecord.nonWageEarningsCents` is the model's own definition
        // of a record's money, and it reads `employeeGratuityFeesCents`
        // UNGUARDED.** A reader that folds first is therefore a SECOND
        // definition of what a shift earned. On reachable data the two agree,
        // which is exactly what makes it dangerous: the disagreement would
        // only ever appear on the data nobody had tested, and "two surfaces
        // disagreeing about one fact" is the thing this project exists to
        // end. The CSV exporter reads the field raw, matching the model; this
        // now does too, so there is one definition rather than two that
        // happen to coincide.
        let cash = record.cashTipsCents
        let credit = record.creditTipsCents
        let metrics = record.receiptMetrics

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
