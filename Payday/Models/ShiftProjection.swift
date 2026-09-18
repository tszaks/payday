import CryptoKit
import Foundation

/// A shift rendered as the legacy rows every existing reader expects.
///
/// PR 2 slice S9. A **struct**, deliberately: it cannot be inserted into a
/// `ModelContext`, so double-counting a shift by accidentally persisting its
/// projection is a compile error rather than something a reviewer has to
/// notice.
struct ProjectedShiftRow: LegacyShiftRow, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let amountCents: Int
    let kind: TipKind
    let note: String?
    let recordedAt: Date?
    let shiftID: UUID?
    let hoursWorked: Double?
    let tipOutCents: Int?
    let salesCents: Int?
    let shiftPeriod: ShiftPeriod?
    let clockIn: Date?
    let clockOut: Date?
    let serverCount: Int?
    let receiptMetrics: ShiftReceiptMetrics?
    let isDouble: Bool
}

enum ShiftProjection {
    /// A namespace of this project's own, so a projected id is a pure function
    /// of the shift it came from and can never collide with a real
    /// `TipEntry.id`.
    private static let namespace = "com.szakacsmedia.payday.projection.v1"

    /// A stable, derived id for one projected row.
    ///
    /// It has to be **deterministic across rebuilds**: identity-keyed SwiftUI
    /// views diff on it, so a fresh UUID each time would make every list
    /// rebuild look like a wholesale replacement and thrash the screen. And it
    /// has to be **distinct per kind**, or the cash and credit rows of one
    /// shift would collide into a single row.
    static func rowID(shiftID: UUID, kind: TipKind) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data(shiftID.uuidString.lowercased().utf8))
        hasher.update(data: Data(kind.rawValue.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        // Stamp version 5 and the RFC 4122 variant, so the result is a
        // well-formed UUID rather than 16 arbitrary bytes wearing the type.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Projects one shift into the rows the legacy readers expect.
    ///
    /// **The rule, stated completely**, because an earlier draft stated it
    /// twice and incompatibly — it said both "emit a credit row and a cash
    /// row" and "a wage-only shift projects as exactly ONE credit row", and
    /// the second forces a per-kind zero-suppression the first forbids. Both
    /// halves of that contradiction cost real money:
    ///
    /// - **Without suppression**, every cash-only shift gains a phantom $0
    ///   Credit row in the day sheet and the history list.
    /// - **With naive suppression**, a cash-only shift — the commonest shape
    ///   there is, for a server who tips the bar out in cash — would emit one
    ///   cash row with every shift-level field nil, so the tip-out resolves to
    ///   0 and a shift worth 4000 reports 5000, with the gratuity and the
    ///   hours vanishing the same way.
    ///
    /// So the rule is exactly `ShiftWriter` plus `ShiftDetails` semantics,
    /// which is what makes it zero-delta against the legacy side:
    ///
    /// 1. One row per kind whose amount is non-zero. If both are zero, exactly
    ///    one row, kind `credit`, amount 0. (A wage-only or gratuity-only
    ///    shift is real and must still carry its hours.)
    /// 2. Every shift-level field goes on the **credit** row when one is
    ///    emitted, otherwise the cash row, otherwise the single zero row. That
    ///    mirrors the detail rank the resolver uses: credit first, then lowest
    ///    id, first non-null across all rows.
    /// 3. `note` and `recordedAt` go on **every** emitted row, because the
    ///    legacy writer passed the note to both initializers. This is what
    ///    keeps the CSV note field byte-identical: a two-kind shift gives
    ///    "N; N" on both sides and a one-kind shift gives "N". Put the note on
    ///    one row only and the exported string diverges.
    static func rows(for shift: ShiftRecord) -> [ProjectedShiftRow] {
        let hasCash = shift.cashTipsCents != 0
        let hasCredit = shift.creditTipsCents != 0

        // Rule 2's "detail rank" in one place: whichever kind carries the
        // shift-level fields.
        let detailKind: TipKind = hasCredit ? .credit : (hasCash ? .cash : .credit)

        func row(kind: TipKind, amountCents: Int) -> ProjectedShiftRow {
            let carriesDetail = kind == detailKind
            return ProjectedShiftRow(
                id: rowID(shiftID: shift.id, kind: kind),
                date: shift.workDate,
                amountCents: amountCents,
                kind: kind,
                // Rule 3: on every row.
                note: shift.note,
                recordedAt: shift.recordedAt,
                shiftID: shift.id,
                hoursWorked: carriesDetail ? shift.hoursWorked : nil,
                tipOutCents: carriesDetail ? shift.tipOutCents : nil,
                salesCents: carriesDetail ? shift.salesCents : nil,
                shiftPeriod: carriesDetail ? shift.shiftPeriod : nil,
                clockIn: carriesDetail ? shift.clockIn : nil,
                clockOut: carriesDetail ? shift.clockOut : nil,
                serverCount: carriesDetail ? shift.serverCount : nil,
                receiptMetrics: carriesDetail ? shift.receiptMetrics : nil,
                // Never projected as a double. `isDouble` was a property of a
                // legacy ROW, and a shift carries its own period instead.
                isDouble: false
            )
        }

        guard hasCash || hasCredit else {
            // Rule 1's tail: one zero-amount credit row, so a wage-only or
            // gratuity-only shift still reaches every reader with its hours,
            // its gratuity and its tip-out attached.
            return [row(kind: .credit, amountCents: 0)]
        }

        var result: [ProjectedShiftRow] = []
        // Credit first, matching the detail rank and the order the legacy
        // writer produced, so any reader that takes `first` sees the same row.
        if hasCredit { result.append(row(kind: .credit, amountCents: shift.creditTipsCents)) }
        if hasCash { result.append(row(kind: .cash, amountCents: shift.cashTipsCents)) }
        return result
    }

    static func rows(for shifts: [ShiftRecord]) -> [ProjectedShiftRow] {
        shifts.flatMap { rows(for: $0) }
    }
}
