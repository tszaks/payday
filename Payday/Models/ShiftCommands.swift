import Foundation
import SwiftData

/// Every mutation of a shift, in one place.
///
/// PR 2 slice S9. Create, edit, delete and undo all come through here, which
/// is what makes three separate claims true at once:
///
/// - **One logical shift saves atomically.** One `save()` per command, and a
///   `rollback()` on any throw, so there is no such thing as half a shift.
/// - **A shift with hours but no tips saves.** The shipped writer appended a
///   row only for a non-zero amount, so a wage-only or gratuity-only shift
///   wrote zero rows and its hours were lost outright.
/// - **A shift the device has not yet confirmed is not editable.** See
///   `Failure.conversionPending`.
@MainActor
enum ShiftCommands {
    /// The user-facing failures, with the copy fixed at the type rather than
    /// at each call site, so two screens cannot word the same refusal
    /// differently.
    enum Failure: Error, Equatable {
        /// The record is gone, usually because another device deleted it.
        case shiftGone
        /// Nothing worth saving was entered.
        case nothingToSave
        /// The store refused the write. Nothing was changed, because the
        /// command rolled back.
        case saveFailed
        /// This record came from a conversion the device has not yet
        /// confirmed. Editing it now could clobber a refold, so it waits
        /// behind the banner and a retry.
        case conversionPending

        var message: String {
            switch self {
            case .shiftGone: "That shift is no longer here."
            case .nothingToSave: "Add tips, hours, or gratuity to save this shift."
            case .saveFailed: "Payday couldn't save that. Nothing was changed."
            case .conversionPending: "Payday is still syncing this shift. Try again in a moment."
            }
        }
    }

    /// Everything needed to put a deleted shift back exactly as it was.
    ///
    /// Delete hard-deletes the local record, so undo cannot read it back off
    /// the store. Capturing the values is what makes undo an exact inverse
    /// rather than a best effort, and the id is captured too so the restored
    /// shift is the SAME shift on the server, not a second one.
    struct DeletedShift: Equatable {
        let id: UUID
        let workDate: Date
        let shiftPeriod: ShiftPeriod?
        let cashTipsCents: Int
        let creditTipsCents: Int
        let tipOutCents: Int?
        let salesCents: Int?
        let hoursWorked: Double?
        let clockIn: Date?
        let clockOut: Date?
        let serverCount: Int?
        let receiptMetrics: ShiftReceiptMetrics?
        let note: String?
        let recordedAt: Date?
        let source: ShiftRecordSource
        let legacyEntryIDs: Set<UUID>
        let deletedAt: Date
    }

    // MARK: - The atomic boundary

    /// One `save()`, and a `rollback()` on any throw.
    ///
    /// `SharedModelContainer` sets `autosaveEnabled = false` so this is
    /// actually atomic: with autosave on, a run-loop save between the mutation
    /// and a throw persists a partial change that `rollback()` cannot undo,
    /// and the atomicity claim above would be false as written.
    ///
    /// That flag lands in THIS slice and not earlier, deliberately. Every
    /// SwiftUI write path in the tree depends on autosave today and several
    /// never call `save()` at all, so turning it off before those paths are
    /// replaced silently stops persisting logged shifts, paychecks and live
    /// field edits — and stops firing `ModelContext.didSave`, which is what
    /// queues a sync, so nothing would sync either.
    private static func perform<T>(in context: ModelContext, _ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            try context.save()
            PaydayWidgetRefresh.request()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    /// The atomic boundary, for the SwiftUI write paths that are not yet
    /// commands.
    ///
    /// Those paths persisted only through autosave and several never called
    /// `save()` at all, which is why `autosaveEnabled = false` could not land
    /// before them: flipping it first silently stops persisting logged shifts,
    /// paychecks and live field edits, and stops firing `ModelContext.didSave`
    /// so nothing syncs either. Each one now wraps its mutations in this, so
    /// the flag and the conversions land together.
    static func commit<T>(in context: ModelContext, _ body: () throws -> T) throws -> T {
        try perform(in: context, body)
    }

    // MARK: - What counts as worth saving

    /// Whether there is anything here to save.
    ///
    /// Hours alone qualify, and gratuity alone qualifies. The shipped writer
    /// appended a row only for a non-zero tip amount, so a wage-only shift
    /// wrote nothing at all and the hours were lost — which also silently
    /// removed that shift from every hourly-rate and overtime calculation.
    static func hasSomethingToSave(
        cashTipsCents: Int,
        creditTipsCents: Int,
        hoursWorked: Double?,
        receiptMetrics: ShiftReceiptMetrics?
    ) -> Bool {
        if cashTipsCents != 0 || creditTipsCents != 0 { return true }
        if let hoursWorked, hoursWorked > 0 { return true }
        if let gratuity = receiptMetrics?.employeeGratuityFeesCents, gratuity != 0 { return true }
        return false
    }

    // MARK: - The write gate

    /// Whether this record may be edited or deleted right now.
    ///
    /// Narrowed deliberately. Refusing every mutation while a conversion is
    /// outstanding was the first design's answer and it was too broad: a shift
    /// the device just authored is read back on the additive legacy leg and
    /// carries one id from birth, so it cannot double-count and there is
    /// nothing to protect.
    ///
    /// What must be refused is editing a record that is a **fold result the
    /// device has not yet confirmed** — non-empty `legacyEntryIDs` while
    /// shifts are not yet authoritative. Editing that before the pull could
    /// clobber a refold.
    static func mayMutate(_ record: ShiftRecord) -> Bool {
        if record.legacyEntryIDs.isEmpty { return true }
        guard let userID = PaydaySyncState.registeredUserID else {
            // Signed out, so no conversion is in flight to race.
            return true
        }
        return PaydaySyncState.shiftsAreAuthoritative(for: userID)
    }

    // MARK: - Commands

    @discardableResult
    static func create(
        in context: ModelContext,
        workDate: Date,
        shiftPeriod: ShiftPeriod? = nil,
        cashTipsCents: Int = 0,
        creditTipsCents: Int = 0,
        tipOutCents: Int? = nil,
        salesCents: Int? = nil,
        hoursWorked: Double? = nil,
        clockIn: Date? = nil,
        clockOut: Date? = nil,
        serverCount: Int? = nil,
        receiptMetrics: ShiftReceiptMetrics? = nil,
        note: String? = nil,
        recordedAt: Date = .now
    ) throws -> ShiftRecord {
        guard hasSomethingToSave(
            cashTipsCents: cashTipsCents,
            creditTipsCents: creditTipsCents,
            hoursWorked: hoursWorked,
            receiptMetrics: receiptMetrics
        ) else { throw Failure.nothingToSave }

        // Clamped to today. A caller may pass an unclamped date, but a shift
        // can never be logged for the future, and the day is the payroll day
        // rather than an instant.
        let day = Calendar.current.startOfDay(for: min(workDate, .now))

        return try perform(in: context) {
            let record = ShiftRecord(
                workDate: day,
                shiftPeriod: shiftPeriod,
                cashTipsCents: cashTipsCents,
                creditTipsCents: creditTipsCents,
                tipOutCents: tipOutCents,
                salesCents: salesCents,
                hoursWorked: hoursWorked,
                clockIn: clockIn,
                clockOut: clockOut,
                serverCount: serverCount,
                receiptMetrics: receiptMetrics,
                note: note,
                recordedAt: recordedAt,
                source: .device
            )
            context.insert(record)
            return record
        }
    }

    /// Applies a set of edits atomically.
    ///
    /// The closure shape matters: it is the same reason `PaydaySyncState`
    /// gained `mutate`. A function taking every field would let a caller erase
    /// what it forgot to pass.
    static func update(
        _ record: ShiftRecord,
        in context: ModelContext,
        _ edits: (ShiftRecord) throws -> Void
    ) throws {
        guard mayMutate(record) else { throw Failure.conversionPending }
        try perform(in: context) {
            try edits(record)
            // `didSet` never fires on a SwiftData model, so nothing advances
            // this on its own and an edited row would never enter the upload
            // set. Measured on 2026-09-17; it is why edits silently stopped
            // syncing in the shipped build.
            record.touch()
        }
    }

    static func delete(
        _ record: ShiftRecord,
        in context: ModelContext,
        at date: Date = .now
    ) throws -> DeletedShift {
        guard mayMutate(record) else { throw Failure.conversionPending }

        let captured = DeletedShift(
            id: record.id,
            workDate: record.workDate,
            shiftPeriod: record.shiftPeriod,
            cashTipsCents: record.cashTipsCents,
            creditTipsCents: record.creditTipsCents,
            tipOutCents: record.tipOutCents,
            salesCents: record.salesCents,
            hoursWorked: record.hoursWorked,
            clockIn: record.clockIn,
            clockOut: record.clockOut,
            serverCount: record.serverCount,
            receiptMetrics: record.receiptMetrics,
            note: record.note,
            recordedAt: record.recordedAt,
            source: record.source,
            legacyEntryIDs: record.legacyEntryIDs,
            deletedAt: date
        )

        return try perform(in: context) {
            // All three inside the same command, so a crash between them
            // cannot leave the server holding a live shift the device thinks
            // it deleted, or vice versa.
            PaydaySyncState.recordShiftDeletion(captured.id, at: date)
            if !captured.legacyEntryIDs.isEmpty {
                // Tombstoning the sources is what makes the deletion visible
                // to a 1.0 build, which reads them and not shifts.
                PaydaySyncState.recordLegacyEntryDeletions(captured.legacyEntryIDs, at: date)
            }
            context.delete(record)
            return captured
        }
    }

    /// The exact inverse of `delete`, down to the id.
    @discardableResult
    static func restore(
        _ deleted: DeletedShift,
        in context: ModelContext,
        at date: Date = .now
    ) throws -> ShiftRecord {
        try perform(in: context) {
            let record = ShiftRecord(
                id: deleted.id,
                workDate: deleted.workDate,
                shiftPeriod: deleted.shiftPeriod,
                cashTipsCents: deleted.cashTipsCents,
                creditTipsCents: deleted.creditTipsCents,
                tipOutCents: deleted.tipOutCents,
                salesCents: deleted.salesCents,
                hoursWorked: deleted.hoursWorked,
                clockIn: deleted.clockIn,
                clockOut: deleted.clockOut,
                serverCount: deleted.serverCount,
                receiptMetrics: deleted.receiptMetrics,
                note: deleted.note,
                recordedAt: deleted.recordedAt,
                source: deleted.source,
                legacyEntryIDs: deleted.legacyEntryIDs
            )
            context.insert(record)

            if let userID = PaydaySyncState.registeredUserID {
                // Un-queue the deletion if it never left, and queue the
                // restore so the server is told either way.
                PaydaySyncState.clearShiftDeletions([deleted.id], for: userID)
                PaydaySyncState.recordShiftRestore(deleted.id, at: date)
                PaydaySyncState.clearShiftTombstones([deleted.id], for: userID)
                // The legacy sources come back too, or a 1.0 build has
                // permanently lost a night the user un-deleted.
                if !deleted.legacyEntryIDs.isEmpty {
                    PaydaySyncState.cancelLegacyEntryDeletions(deleted.legacyEntryIDs)
                }
            }
            return record
        }
    }
}
