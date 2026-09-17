import Foundation

/// A real paycheck as entered from the stub. Only `paidTipsCents` is
/// required; every other line is optional because stubs differ and the
/// user may enter only what they have. `PaycheckReconciler` (PR 4) compares
/// these against the engine's expected figures for the same period.
public struct PaycheckInput: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var periodStart: CivilDay
    public var periodEnd: CivilDay
    /// `MetricID.observedPaidTips`, exactly as entered.
    public var paidTipsCents: Int
    public var grossPayCents: Int?
    public var netPayCents: Int?
    public var regularWagesCents: Int?
    public var overtimeWagesCents: Int?
    public var gratuityCents: Int?
    public var taxesCents: Int?

    public init(
        id: UUID,
        periodStart: CivilDay,
        periodEnd: CivilDay,
        paidTipsCents: Int,
        grossPayCents: Int? = nil,
        netPayCents: Int? = nil,
        regularWagesCents: Int? = nil,
        overtimeWagesCents: Int? = nil,
        gratuityCents: Int? = nil,
        taxesCents: Int? = nil
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.paidTipsCents = paidTipsCents
        self.grossPayCents = grossPayCents
        self.netPayCents = netPayCents
        self.regularWagesCents = regularWagesCents
        self.overtimeWagesCents = overtimeWagesCents
        self.gratuityCents = gratuityCents
        self.taxesCents = taxesCents
    }

    public var period: DayRange { DayRange(start: periodStart, end: periodEnd) }
}
