import Foundation

/// The single place the "hours/tip-out/sales belong to the shift (one
/// closeout), never to one entry or tip type" rule is enforced — on read
/// (resolve) and on write (write). Callers pass a SINGLE shift's entries
/// (the rows sharing one shiftID), not a whole day — a double day has two
/// independent shifts, each with its own canonical entry. This is a product
/// ruling, not a UI convenience: StatsEngine, CSVExporter, WageEstimate,
/// PeriodIncome, LogTipsIntent and every shift row resolve through here too,
/// so a corrupted shift (a value stray on the "wrong" entry, or set on both
/// at once) reads as one number everywhere in the app, never a
/// double-counted one.
///
/// ## Ranking, not `first(where:)`
///
/// A shift is usually one cash row plus one credit row, and for that shape
/// "credit ?? cash" and "the first non-nil in rank order" are the same
/// answer. They are NOT the same answer on a group holding TWO rows of one
/// kind, which is reachable today with no data corruption at all:
///
/// - the agent API's `create_tip_entry` mints row ids as
///   `deterministicUUID("shift:<shift_id>:credit")`, which never equals a
///   device row's random UUID and is under no uniqueness constraint on
///   (shift_id, kind), so an agent adding credit tips to an existing device
///   shift lands a SECOND credit row in that group; and
/// - `MigrationRunner.backfillShiftIDs` assigns one day's existing shiftID
///   to every nil-shift_id row of that day, which collapses a legacy pair
///   and a new pair into one four-row group.
///
/// `entries.first { $0.kind == .credit }` on such a group is decided by
/// ARRAY ORDER, and the two orders give different money. Measured on the
/// four-row group (cash 5000 id a1, credit 2000 tip-out 1000 id b1, cash
/// 1000 id c1, credit 3000 carrying a v1 receipt with gratuity 4200 id d1):
/// id order gave cash 6000 / credit 5000 / gratuity 0 / tip-out 1000 /
/// net 10000, and receipt-row-first gave 6000 / 2000 / 4200 / 0 / 12200.
/// Two answers for identical data, and `private.derive_shifts` agrees with
/// neither: the server folds that group to 6000 / 2000 / 4200 / 1000 /
/// 11200.
///
/// So this file now carries the deriver's ranking verbatim, and the two
/// ranks are separate on purpose because the SQL keeps them separate:
///
/// - `detailRank` — credit first, then id ascending — resolves hours,
///   tip-out, sales, period, clock in/out and server count, each as the
///   first NON-NIL value in that order across ALL of the group's rows. This
///   is `row_number() over (order by (kind = 'credit') desc, id asc)` plus
///   `(array_agg(col order by detail_rank) filter (where col is not null))[1]`.
/// - `metricsRank` — a row that actually carries a decodable receipt first,
///   then credit, then id ascending — resolves the receipt owner. This is
///   `row_number() over (order by (jsonb_typeof(receipt_metrics) = 'object')
///   desc nulls last, (kind = 'credit') desc, id asc)`. Object-first is what
///   keeps the gratuity OWNER and the group's stored payload the same row,
///   and on the server it is worth $42.00 on a single shift.
///
/// Both ranks are total and order-independent: the same rows in any array
/// order resolve to the same values. Pinned on both sides of the wall by
/// `PaydayTests/ShiftGroupRankingParityTests.swift` and by fixture P7 in
/// `supabase/tests/shift_deriver_test.sql`, which carry the SAME numbers as
/// literals. Neither side re-derives; if you change one rule, both fail.
///
/// One known asymmetry, deliberately not papered over: SQL ranks on
/// `jsonb_typeof(...) = 'object'`, while Swift can only see a payload that
/// DECODES as `ShiftReceiptMetrics`. A payload that is a JSON object but
/// undecodable (`{"gratuityFeesCents": "42"}`) is object on the server and
/// nil here. The deriver's sanitizer rewrites `gratuityFeesCents` through
/// `private.receipt_gratuity_cents` precisely so every STORED payload
/// decodes, so the asymmetry is confined to un-folded legacy rows, where
/// `ShiftRecord.receiptPayloadIsUnreadable` is the surface that reports it.
enum ShiftDetails {
    /// The group's rows in `detail_rank` order: credit first, then id
    /// ascending. `id.uuidString` is compared rather than the UUID itself
    /// because `UUID` is not `Comparable`; the canonical string is fixed-case
    /// hex in byte order, so its lexicographic order is exactly Postgres'
    /// `order by id asc` (a memcmp over the same 16 bytes).
    static func detailRanked(_ entries: [TipEntry]) -> [TipEntry] {
        entries.sorted { left, right in
            let leftCredit = left.kind == .credit
            let rightCredit = right.kind == .credit
            if leftCredit != rightCredit { return leftCredit }
            return left.id.uuidString < right.id.uuidString
        }
    }

    /// The group's rows in `metrics_rank` order: a row carrying a decodable
    /// receipt first, then credit, then id ascending.
    static func metricsRanked(_ entries: [TipEntry]) -> [TipEntry] {
        entries.sorted { left, right in
            let leftHas = left.receiptMetrics != nil
            let rightHas = right.receiptMetrics != nil
            if leftHas != rightHas { return leftHas }
            let leftCredit = left.kind == .credit
            let rightCredit = right.kind == .credit
            if leftCredit != rightCredit { return leftCredit }
            return left.id.uuidString < right.id.uuidString
        }
    }

    /// The ONE row of a shift that owns the receipt, and therefore the one
    /// row a v1 payload's gratuity is subtracted from. Nil when no row in the
    /// group carries a decodable payload. `TipBreakdown` must resolve the
    /// owner through here and nowhere else: a duplicated payload on a second
    /// row must not subtract gratuity twice.
    static func metricsOwner(of entries: [TipEntry]) -> TipEntry? {
        metricsRanked(entries).first { $0.receiptMetrics != nil }
    }

    /// The canonical hours/tip-out/sales/shift-period/clock/server-count and
    /// receipt for one shift's entries: each field is the first NON-NIL value
    /// in rank order across every row of the group, and NEVER a sum.
    static func resolve(from entries: [TipEntry]) -> (hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?, clockIn: Date?, clockOut: Date?, serverCount: Int?, receiptMetrics: ShiftReceiptMetrics?) {
        let ranked = detailRanked(entries)
        func first<Value>(_ field: (TipEntry) -> Value?) -> Value? {
            for entry in ranked {
                if let value = field(entry) { return value }
            }
            return nil
        }
        return (
            hoursWorked: first(\.hoursWorked),
            tipOutCents: first(\.tipOutCents),
            salesCents: first(\.salesCents),
            shiftPeriod: first(\.shiftPeriod),
            clockIn: first(\.clockIn),
            clockOut: first(\.clockOut),
            serverCount: first(\.serverCount),
            receiptMetrics: metricsOwner(of: entries)?.receiptMetrics
        )
    }

    /// Writes hours/tip-out/sales/shift-period/clockIn/clockOut/serverCount
    /// onto the one canonical entry for a shift (detail rank 1: credit
    /// first, then lowest id) and clears them from every other entry in
    /// that shift — self-healing any data where a value ended up set on
    /// more than one entry. clockIn/clockOut/serverCount default to nil so
    /// existing call sites (and tests) that only care about the earlier
    /// fields keep compiling.
    ///
    /// Every entry written here is `touch()`ed, because this is the shared
    /// write path for every shift-level edit in the app (LogTipSheet's live
    /// edit, ShiftWriter's insert, BackfillSheet, LogTipsIntent, the receipt
    /// apply path, DebugSeeder) and a shift edit that does not advance
    /// `modifiedAt` uploads a stale `client_updated_at`. Touching an entry
    /// whose values happen to be unchanged is free — the upload set is chosen
    /// by content fingerprint, not by the clock.
    static func write(hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?, clockIn: Date? = nil, clockOut: Date? = nil, serverCount: Int? = nil, receiptMetrics: ShiftReceiptMetrics? = nil, into entries: [TipEntry], at date: Date = .now) {
        // detail rank 1, not `entries.first(where:)`: the row this writes
        // onto has to be the row `resolve` reads first, and on a group with
        // two rows of one kind `first(where:)` is decided by array order.
        guard let primary = detailRanked(entries).first else { return }
        for entry in entries where entry.id != primary.id {
            entry.hoursWorked = nil
            entry.tipOutCents = nil
            entry.salesCents = nil
            entry.shiftPeriod = nil
            entry.clockIn = nil
            entry.clockOut = nil
            entry.serverCount = nil
            entry.receiptMetrics = nil
            entry.touch(at: date)
        }
        primary.hoursWorked = hoursWorked
        primary.tipOutCents = tipOutCents
        primary.salesCents = salesCents
        primary.shiftPeriod = shiftPeriod
        primary.clockIn = clockIn
        primary.clockOut = clockOut
        primary.serverCount = serverCount
        primary.receiptMetrics = receiptMetrics
        primary.touch(at: date)
    }
}
