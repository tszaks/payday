import Foundation

/// The sentences a person reads under CHECKS on the paycheck sheet.
///
/// **Copy only.** Every integer this file prints arrived on a
/// `PaycheckReconciler.Reconciliation`; nothing here adds, subtracts, scales
/// or rounds a cent. That is the PR 5 adapter contract applied to an audit:
/// before group 2.5 this type performed eight of its own sums (the stub's
/// earned total, gross minus taxes, the stub's two wage lines, five
/// differences and four `abs` comparisons) over inputs a screen had already
/// composed, so the numbers a person was told were "off" were computed in a
/// third place from a second basis. `PaycheckReconciler` owns the arithmetic,
/// `docs/METRICS.md` PE-06..PE-11 are its rows, and this file owns only which
/// sentence to say.
///
/// What it still owns, deliberately:
///
/// - **The tolerances.** 5c on stub-printed figures, because a stub carries a
///   cent of rounding drift that is not a discrepancy; 100c on wages against
///   punches, because punch rounding and rate mismatches compound faster than
///   that. `docs/METRICS.md` 1.3 records unifying them as an open decision;
///   this change does not take it.
/// - **Silence.** Each check fires only when every input it needs is present.
///   A blank field stays quiet rather than nagging, and an unbacked
///   expectation silences every engine-side check while the two
///   stub-internal ones still run — they need nothing from the engine.
/// - **The red/green rule, unchanged:** a `.discrepancy` reads red, and only
///   a shortfall or an impossibility is one. A stub that pays MORE than
///   expected is a `.note`, per `MetricID.reconciliationDelta`'s "red only
///   when < 0".
///
/// Pure and I/O-free, so the sheet can re-run it on every keystroke.
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

    /// Rounding slop on stub-printed figures — pay stubs occasionally carry
    /// a cent of rounding drift that isn't a real discrepancy.
    private static let centsTolerance = 5

    /// Wages computed from punches vs. the stub's own wage lines tolerate a
    /// full dollar — punch rounding and rate mismatches compound faster than
    /// the cent-level tolerance above allows for.
    private static let wagesTolerance = 100

    /// Every finding for one reconciliation, in reading order.
    ///
    /// One argument, and that is the point: the expected side, the observed
    /// side and every delta arrive together, from the same dataset, stamped.
    /// The previous signature took five loose values a caller assembled
    /// itself, which is how the sheet came to audit against a basis the
    /// screen behind it did not use (`PaycheckReconciler.Expectation`'s
    /// header has the $310.00 measurement).
    static func run(_ reconciliation: PaycheckReconciler.Reconciliation) -> [Finding] {
        [
            grossMathFinding(reconciliation),
            netMathFinding(reconciliation),
            tipsVsLoggedFinding(reconciliation),
            gratuityVsLoggedFinding(reconciliation),
            wagesVsComputedFinding(reconciliation),
            overtimeMissingFinding(reconciliation),
        ].compactMap { $0 }
    }

    // MARK: - Stub-internal checks (need nothing from the engine)

    /// PE-06. The stub's own lines against its printed gross.
    private static func grossMathFinding(
        _ reconciliation: PaycheckReconciler.Reconciliation
    ) -> Finding? {
        let observed = reconciliation.observation
        guard let earnedCents = observed.stubEarnedCents,
              let grossCents = observed.grossCents,
              let deltaCents = reconciliation.stubInternalGrossDeltaCents
        else { return nil }
        let components = observed.gratuityCents == nil ? "Tips and wages" : "Tips, wages, and gratuity"
        guard abs(deltaCents) > centsTolerance else {
            return Finding(id: "gross-math", severity: .reconciles, message: "\(components) add up to the gross.")
        }
        let earned = moneyString(earnedCents)
        let gross = moneyString(grossCents)
        let unaccounted = moneyString(abs(deltaCents))
        return Finding(id: "gross-math", severity: .discrepancy, message: "\(components) come to \(earned) - the stub's gross is \(gross). \(unaccounted) unaccounted.")
    }

    /// PE-07. Gross minus taxes against the printed net.
    private static func netMathFinding(
        _ reconciliation: PaycheckReconciler.Reconciliation
    ) -> Finding? {
        let observed = reconciliation.observation
        guard let expectedCents = observed.grossMinusTaxesCents,
              let netCents = observed.netCents,
              let deltaCents = reconciliation.stubInternalNetDeltaCents
        else { return nil }
        guard abs(deltaCents) > centsTolerance else {
            return Finding(id: "net-math", severity: .reconciles, message: "Gross minus taxes matches the net.")
        }
        if deltaCents < 0 {
            let expected = moneyString(expectedCents)
            let net = moneyString(netCents)
            let difference = moneyString(-deltaCents)
            return Finding(id: "net-math", severity: .note, message: "Gross minus taxes leaves \(expected); net is \(net). \(difference) in other deductions or withholdings.")
        }
        return Finding(id: "net-math", severity: .discrepancy, message: "Net is higher than gross minus taxes - one of these numbers is off.")
    }

    // MARK: - Engine-side checks (silent without an expectation)

    /// PE-08. `MetricID.reconciliationDelta`, tips component.
    ///
    /// The copy says "credit tips" and the expected figure is the credit side
    /// NET of tip-out, which is what payroll prints. A period with no credit
    /// tips produces no expected side at all
    /// (`Expectation.auditableTipsLineCents`) and therefore no finding: a
    /// legacy all-cash period is not a discrepancy.
    private static func tipsVsLoggedFinding(
        _ reconciliation: PaycheckReconciler.Reconciliation
    ) -> Finding? {
        guard let tipsCents = reconciliation.observation.paidTipsCents,
              let loggedCreditTipsCents = reconciliation.expectation.auditableTipsLineCents,
              let deltaCents = reconciliation.tipsDeltaCents
        else { return nil }
        guard abs(deltaCents) > centsTolerance else {
            return Finding(id: "tips-vs-logged", severity: .reconciles, message: "Tips match what you logged.")
        }
        let logged = moneyString(loggedCreditTipsCents)
        let stubTips = moneyString(tipsCents)
        let difference = moneyString(abs(deltaCents))
        let direction = deltaCents < 0 ? "short" : "over"
        return Finding(id: "tips-vs-logged", severity: .discrepancy, message: "You logged \(logged) in credit tips; the stub pays \(stubTips) in tips. \(difference) \(direction).")
    }

    /// PE-03 / PE-08. Toast mandatory gratuity is its own payroll category.
    /// Comparing it independently prevents an overage in one category from
    /// hiding a shortage in the other.
    private static func gratuityVsLoggedFinding(
        _ reconciliation: PaycheckReconciler.Reconciliation
    ) -> Finding? {
        guard let loggedGratuityCents = reconciliation.expectation.gratuityFeesCents else { return nil }
        guard let gratuityCents = reconciliation.observation.gratuityCents,
              let deltaCents = reconciliation.gratuityDeltaCents
        else {
            return Finding(
                id: "gratuity-vs-logged",
                severity: .note,
                message: "You logged \(moneyString(loggedGratuityCents)) in gratuity and fees; no gratuity line was entered from the stub."
            )
        }
        guard abs(deltaCents) > centsTolerance else {
            return Finding(id: "gratuity-vs-logged", severity: .reconciles, message: "Gratuity matches what you logged.")
        }
        let logged = moneyString(loggedGratuityCents)
        let stubGratuity = moneyString(gratuityCents)
        let difference = moneyString(abs(deltaCents))
        let direction = deltaCents < 0 ? "short" : "over"
        return Finding(id: "gratuity-vs-logged", severity: .discrepancy, message: "You logged \(logged) in gratuity and fees; the stub pays \(stubGratuity) in gratuity. \(difference) \(direction).")
    }

    /// PE-10. `MetricID.reconciliationDelta`, wages component: the stub's two
    /// wage lines against the LEDGER's regular/overtime split for the same
    /// period, on the payroll calendar policy's workweek.
    private static func wagesVsComputedFinding(
        _ reconciliation: PaycheckReconciler.Reconciliation
    ) -> Finding? {
        guard let stubWagesCents = reconciliation.observation.stubWagesCents,
              let regularCents = reconciliation.expectation.regularWagesCents,
              let overtimeCents = reconciliation.expectation.overtimeWagesCents,
              let deltaCents = reconciliation.wagesDeltaCents
        else { return nil }
        guard abs(deltaCents) > wagesTolerance else {
            return Finding(id: "wages-vs-computed", severity: .reconciles, message: "Wages match Payday's math from your punches.")
        }
        if deltaCents < 0 {
            let regular = moneyString(regularCents)
            let overtime = moneyString(overtimeCents)
            let stubWages = moneyString(stubWagesCents)
            let owed = moneyString(-deltaCents)
            return Finding(id: "wages-vs-computed", severity: .discrepancy, message: "From your punches Payday computes \(regular) regular and \(overtime) overtime - the stub pays \(stubWages). You may be owed \(owed).")
        }
        let extra = moneyString(deltaCents)
        return Finding(id: "wages-vs-computed", severity: .note, message: "The stub pays \(extra) more in wages than Payday computes from your punches.")
    }

    /// PE-11. The hours facet of `MetricID.overtimeWages`: the ledger found
    /// overtime in this period's workweeks and the stub prints none.
    ///
    /// Minutes, not decimal hours. `WorkedMinutes.hoursLabel` is the one
    /// hours spelling in the app and the engine, so "11h 30m" here and on a
    /// shift row are the same function and a punch stays literal.
    private static func overtimeMissingFinding(
        _ reconciliation: PaycheckReconciler.Reconciliation
    ) -> Finding? {
        guard let overtimeMinutes = reconciliation.expectation.overtimeMinutes,
              overtimeMinutes > 0
        else { return nil }
        let observed = reconciliation.observation
        guard observed.overtimeWagesCents == nil || observed.overtimeWagesCents == 0 else { return nil }
        guard observed.hasAnyNonWageField || observed.regularWagesCents != nil else { return nil }
        let hours = WorkedMinutes.hoursLabel(minutes: overtimeMinutes)
        return Finding(id: "overtime-missing", severity: .discrepancy, message: "Your punches add up to \(hours) overtime hours this period; the stub shows no overtime pay.")
    }

    /// Whole dollars when the amount is an even dollar figure, cents otherwise.
    private static func moneyString(_ cents: Int) -> String {
        cents % 100 == 0 ? Money.wholeDollarString(fromCents: cents) : Money.string(fromCents: cents)
    }
}
