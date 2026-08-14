import Foundation

/// Reconciliation checks over a paycheck stub — the numbers an accountant or
/// a financial planner would inspect a paycheck for: do tips plus wages add
/// up to the gross, does gross minus taxes match the net, does the stub's
/// tips line match what was logged, and do the stub's wages match what
/// Payday computes from punches. Pure and I/O-free so PaycheckEntrySheet can
/// re-run it on every keystroke; each check only fires when every input it
/// needs is present — a field left blank stays silent rather than nagging.
struct PaycheckAudit {
    enum Severity {
        case reconciles
        case discrepancy
        case note
    }

    struct Finding: Equatable, Identifiable {
        let id: String
        let severity: Severity
        let message: String
    }

    /// The entry sheet's current fields — zero-means-nil, same convention as
    /// everywhere else: "not entered" and "entered as zero" are different
    /// facts, but this sheet (like LogTipSheet) never lets a field record
    /// the latter.
    struct Stub: Equatable {
        let tipsCents: Int?
        let regularWagesCents: Int?
        let overtimeWagesCents: Int?
        let gratuityCents: Int?
        let grossCents: Int?
        let taxesCents: Int?
        let netCents: Int?

        init(
            tipsCents: Int?,
            regularWagesCents: Int?,
            overtimeWagesCents: Int?,
            gratuityCents: Int? = nil,
            grossCents: Int?,
            taxesCents: Int?,
            netCents: Int?
        ) {
            self.tipsCents = tipsCents
            self.regularWagesCents = regularWagesCents
            self.overtimeWagesCents = overtimeWagesCents
            self.gratuityCents = gratuityCents
            self.grossCents = grossCents
            self.taxesCents = taxesCents
            self.netCents = netCents
        }
    }

    /// Rounding slop on stub-printed figures — pay stubs occasionally carry
    /// a cent of rounding drift that isn't a real discrepancy.
    private static let centsTolerance = 5

    /// Wages computed from punches vs. the stub's own wage lines tolerate a
    /// full dollar — punch rounding and rate mismatches compound faster than
    /// the cent-level tolerance above allows for.
    private static let wagesTolerance = 100

    static func run(stub: Stub, loggedCreditTipsCents: Int?, computedWages: PeriodIncome.Wages?, computedOvertimeHours: Double?) -> [Finding] {
        [
            grossMathFinding(stub: stub),
            netMathFinding(stub: stub),
            tipsVsLoggedFinding(stub: stub, loggedCreditTipsCents: loggedCreditTipsCents),
            wagesVsComputedFinding(stub: stub, computedWages: computedWages),
            overtimeMissingFinding(stub: stub, computedOvertimeHours: computedOvertimeHours),
        ].compactMap { $0 }
    }

    private static func grossMathFinding(stub: Stub) -> Finding? {
        guard let tipsCents = stub.tipsCents, let grossCents = stub.grossCents else { return nil }
        let earnedCents = tipsCents + (stub.regularWagesCents ?? 0) + (stub.overtimeWagesCents ?? 0) + (stub.gratuityCents ?? 0)
        let components = stub.gratuityCents == nil ? "Tips and wages" : "Tips, wages, and gratuity"
        guard abs(earnedCents - grossCents) > centsTolerance else {
            return Finding(id: "gross-math", severity: .reconciles, message: "\(components) add up to the gross.")
        }
        let earned = moneyString(earnedCents)
        let gross = moneyString(grossCents)
        let unaccounted = moneyString(abs(grossCents - earnedCents))
        return Finding(id: "gross-math", severity: .discrepancy, message: "\(components) come to \(earned) - the stub's gross is \(gross). \(unaccounted) unaccounted.")
    }

    private static func netMathFinding(stub: Stub) -> Finding? {
        guard let grossCents = stub.grossCents, let taxesCents = stub.taxesCents, let netCents = stub.netCents else { return nil }
        let expectedCents = grossCents - taxesCents
        guard abs(netCents - expectedCents) > centsTolerance else {
            return Finding(id: "net-math", severity: .reconciles, message: "Gross minus taxes matches the net.")
        }
        if netCents < expectedCents {
            let expected = moneyString(expectedCents)
            let net = moneyString(netCents)
            let difference = moneyString(expectedCents - netCents)
            return Finding(id: "net-math", severity: .note, message: "Gross minus taxes leaves \(expected); net is \(net). \(difference) in other deductions or withholdings.")
        }
        return Finding(id: "net-math", severity: .discrepancy, message: "Net is higher than gross minus taxes - one of these numbers is off.")
    }

    private static func tipsVsLoggedFinding(stub: Stub, loggedCreditTipsCents: Int?) -> Finding? {
        guard let tipsCents = stub.tipsCents, let loggedCreditTipsCents else { return nil }
        guard abs(tipsCents - loggedCreditTipsCents) > centsTolerance else {
            return Finding(id: "tips-vs-logged", severity: .reconciles, message: "The tips line matches what you logged.")
        }
        let logged = moneyString(loggedCreditTipsCents)
        let stubTips = moneyString(tipsCents)
        let difference = moneyString(abs(tipsCents - loggedCreditTipsCents))
        let direction = tipsCents < loggedCreditTipsCents ? "short" : "over"
        return Finding(id: "tips-vs-logged", severity: .discrepancy, message: "You logged \(logged) in credit tips; the stub pays \(stubTips). \(difference) \(direction).")
    }

    private static func wagesVsComputedFinding(stub: Stub, computedWages: PeriodIncome.Wages?) -> Finding? {
        guard stub.regularWagesCents != nil || stub.overtimeWagesCents != nil, let computedWages else { return nil }
        let stubWagesCents = (stub.regularWagesCents ?? 0) + (stub.overtimeWagesCents ?? 0)
        let computedCents = computedWages.totalCents
        guard abs(stubWagesCents - computedCents) > wagesTolerance else {
            return Finding(id: "wages-vs-computed", severity: .reconciles, message: "Wages match Payday's math from your punches.")
        }
        if stubWagesCents < computedCents {
            let regular = moneyString(computedWages.regularCents)
            let overtime = moneyString(computedWages.overtimeCents)
            let stubWages = moneyString(stubWagesCents)
            let owed = moneyString(computedCents - stubWagesCents)
            return Finding(id: "wages-vs-computed", severity: .discrepancy, message: "From your punches Payday computes \(regular) regular and \(overtime) overtime - the stub pays \(stubWages). You may be owed \(owed).")
        }
        let extra = moneyString(stubWagesCents - computedCents)
        return Finding(id: "wages-vs-computed", severity: .note, message: "The stub pays \(extra) more in wages than Payday computes from your punches.")
    }

    private static func overtimeMissingFinding(stub: Stub, computedOvertimeHours: Double?) -> Finding? {
        guard let computedOvertimeHours, computedOvertimeHours > 0 else { return nil }
        guard stub.overtimeWagesCents == nil || stub.overtimeWagesCents == 0 else { return nil }
        let hasOtherStubField = stub.tipsCents != nil || stub.regularWagesCents != nil || stub.grossCents != nil || stub.taxesCents != nil || stub.netCents != nil
        guard hasOtherStubField else { return nil }
        let hours = WageEstimate.hoursLabel(computedOvertimeHours)
        return Finding(id: "overtime-missing", severity: .discrepancy, message: "Your punches add up to \(hours) overtime hours this period; the stub shows no overtime pay.")
    }

    /// Whole dollars when the amount is an even dollar figure, cents otherwise.
    private static func moneyString(_ cents: Int) -> String {
        cents % 100 == 0 ? Money.wholeDollarString(fromCents: cents) : Money.string(fromCents: cents)
    }
}
