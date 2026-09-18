import Foundation

/// Everything one snapshot is computed from, in one `Sendable` value.
///
/// It exists so the fetch/adapt step (main actor, SwiftData, UserDefaults)
/// and the build step (detached, pure) have exactly one thing to hand each
/// other. `EarningsStore` adapts on the main actor, fingerprints, and then
/// sends one of these off the main thread; `EarningsStore.buildOnce` (widget,
/// Siri) builds one and returns without publishing anything.
public struct EarningsInputs: Hashable, Sendable {
    public var shifts: [ShiftInput]
    public var paychecks: [PaycheckInput]
    public var schedule: PayScheduleInput?
    public var rates: [PayRatePolicy]
    public var calendars: [PayrollCalendarPolicy]
    /// The cutoff for every period-to-date query: today, in the FROZEN
    /// payroll time zone, never the device's.
    public var asOf: CivilDay
    public var engineVersion: Int

    /// Shifts whose stored receipt payload is present but will not decode
    /// (`ShiftRecord.receiptPayloadIsUnreadable`). Their gratuity therefore
    /// reads as zero in `shifts` above, so the ids travel with the snapshot
    /// rather than being lost: a number that is low for a knowable reason
    /// must stay attributable. Deliberately NOT part of the manifest digest
    /// — the readable/unreadable distinction is visible in the encoded
    /// `gratuityFeesCents` already, so including it would change the digest
    /// for the same dataset.
    public var unreadableReceiptShiftIDs: [UUID]

    public init(
        shifts: [ShiftInput],
        paychecks: [PaycheckInput] = [],
        schedule: PayScheduleInput? = nil,
        rates: [PayRatePolicy] = [],
        calendars: [PayrollCalendarPolicy] = [],
        asOf: CivilDay,
        engineVersion: Int = InputManifest.currentEngineVersion,
        unreadableReceiptShiftIDs: [UUID] = []
    ) {
        self.shifts = shifts
        self.paychecks = paychecks
        self.schedule = schedule
        self.rates = rates
        self.calendars = calendars
        self.asOf = asOf
        self.engineVersion = engineVersion
        self.unreadableReceiptShiftIDs = unreadableReceiptShiftIDs
    }

    /// The fingerprint of these inputs. Throws `InputManifest
    /// .ValidationError` for an input that cannot be canonically encoded, so
    /// a corrupt payload is a reportable error and never a silent digest
    /// collision.
    public func manifest() throws -> InputManifest {
        try InputManifest(
            shifts: shifts,
            paychecks: paychecks,
            schedule: schedule,
            rates: rates,
            calendars: calendars,
            asOf: asOf,
            engineVersion: engineVersion
        )
    }
}
