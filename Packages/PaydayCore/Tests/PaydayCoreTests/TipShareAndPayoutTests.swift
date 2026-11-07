import Foundation
import Testing
@testable import PaydayCore

/// PR A: a received tip share (`EarningsComponents.tipShareInCents`) and
/// where card tips are paid (`PaycheckReconciler`'s `cardTipsOnCheck`).
/// Synthetic round numbers throughout.
@Suite("Tip share received and card tips paid at close")
struct TipShareAndPayoutTests {
    /// The acceptance case: a bartender with no card tips, $180 share in,
    /// $40 tipped out.
    let bartender = EarningsComponents(tipOutCents: 4000, tipShareInCents: 18000)

    @Test("a received share is earned money but never a tip the guest left")
    func shareIsEarnedNotVoluntary() {
        #expect(bartender.nonWageEarningsCents == 14000)
        #expect(bartender.earnedIncomeCents == 14000)
        #expect(bartender.voluntaryTipsCents == 0)
        #expect(bartender.grossBeforeTipOutCents == 18000)
    }

    @Test("the share adds and subtracts component-wise")
    func shareIsAdditive() {
        let other = EarningsComponents(voluntaryCreditCents: 1000, tipShareInCents: 500)
        #expect((bartender + other).tipShareInCents == 18500)
        #expect((bartender + other - other) == bartender)
    }

    @Test("a document written before the share existed still decodes, as 0")
    func legacyJSONDecodes() throws {
        let json = #"{"voluntaryCashCents":100,"voluntaryCreditCents":200,"gratuityFeesCents":0,"tipOutCents":50,"regularWagesCents":0,"overtimeWagesCents":0}"#
        let decoded = try JSONDecoder().decode(EarningsComponents.self, from: Data(json.utf8))
        #expect(decoded.tipShareInCents == 0)
        #expect(decoded.nonWageEarningsCents == 250)
        let roundTrip = try JSONDecoder().decode(
            EarningsComponents.self, from: JSONEncoder().encode(bartender))
        #expect(roundTrip == bartender)
    }

    @Test("ShiftInput carries the share into its components; nil is 0")
    func shiftInputCarriesShare() {
        let day = CivilDay(iso: "2026-10-05")!
        let with = ShiftInput(id: UUID(), workDay: day, tipOutCents: 4000, tipShareInCents: 18000)
        let without = ShiftInput(id: UUID(), workDay: day, tipOutCents: 4000)
        #expect(with.nonWageComponents.nonWageEarningsCents == 14000)
        #expect(without.nonWageComponents.tipShareInCents == 0)
    }

    @Test("the manifest digest moves for a share and is unchanged without one")
    func manifestDigest() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let day = CivilDay(iso: "2026-10-05")!
        let plain = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000)
        let zero = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000, tipShareInCents: 0)
        let shared = ShiftInput(id: id, workDay: day, voluntaryCashCents: 1000, tipShareInCents: 500)
        let lines = InputManifest.Canonical.shiftLines
        #expect(lines([plain]) == lines([zero]))
        #expect(!lines([plain])[0].contains("tsi="))
        #expect(lines([shared])[0].hasSuffix("|tsi=500"))
    }

    // MARK: - The paycheck

    @Test("on the check, the share rides with the card tips")
    func onCheckShareIsOnTheTipsLine() {
        #expect(PaycheckReconciler.tipsLineCents(from: bartender) == 14000)
        let mixed = EarningsComponents(
            voluntaryCashCents: 2000, voluntaryCreditCents: 6000, gratuityFeesCents: 1000,
            tipOutCents: 5000, tipShareInCents: 18000, regularWagesCents: 5500)
        #expect(PaycheckReconciler.tipsLineCents(from: mixed) == 19000)
        #expect(PaycheckReconciler.grossCents(from: mixed) == 25500)
        #expect(PaycheckReconciler.tipsAlreadyPaidCents(from: mixed, cardTipsOnCheck: true) == 2000)
    }

    @Test("paid at close: no tips line, gross is gratuity + wages, tips already paid is the rest")
    func atCloseHasNoTipsLine() {
        let mixed = EarningsComponents(
            voluntaryCashCents: 2000, voluntaryCreditCents: 6000, gratuityFeesCents: 1000,
            tipOutCents: 5000, tipShareInCents: 18000, regularWagesCents: 5500)
        #expect(PaycheckReconciler.tipsLineCents(from: mixed, cardTipsOnCheck: false) == 0)
        #expect(PaycheckReconciler.tipsAndGratuityCents(from: mixed, cardTipsOnCheck: false) == 1000)
        #expect(PaycheckReconciler.grossCents(from: mixed, cardTipsOnCheck: false) == 6500)
        #expect(PaycheckReconciler.tipsAlreadyPaidCents(from: mixed, cardTipsOnCheck: false) == 21000)
    }

    @Test("the default is on the check, so existing call sites are unchanged")
    func defaultIsOnTheCheck() {
        let credit = EarningsComponents(voluntaryCashCents: 1000, voluntaryCreditCents: 8000, tipOutCents: 500)
        #expect(PaycheckReconciler.tipsLineCents(from: credit)
                == PaycheckReconciler.tipsLineCents(from: credit, cardTipsOnCheck: true))
        #expect(PaycheckReconciler.tipsLineCents(from: credit) == 7500)
    }

    @Test("the Expectation audits the tips line only when tips are on the check")
    func expectationFollowsTheSetting() throws {
        let day = CivilDay(iso: "2026-10-05")!
        let shift = ShiftInput(
            id: UUID(), workDay: day, voluntaryCreditCents: 6000, tipOutCents: 1000,
            tipShareInCents: 3000, minutesWorked: 300)
        let snapshot = try EarningsSnapshot.build(
            EarningsInputs(shifts: [shift], paychecks: [], schedule: nil, rates: [], calendars: [], asOf: .distantFuture))
        let result = snapshot.range(DayRange(start: day, end: day))

        let onCheck = PaycheckReconciler.Expectation(result: result, stamp: snapshot.stamp)
        #expect(onCheck.cardTipsOnCheck)
        #expect(onCheck.tipsLineCents == 8000)
        #expect(onCheck.auditableTipsLineCents == 8000)

        let atClose = PaycheckReconciler.Expectation(
            result: result, stamp: snapshot.stamp, cardTipsOnCheck: false)
        #expect(atClose.tipsLineCents == 0)
        #expect(atClose.auditableTipsLineCents == nil)
        #expect(atClose.grossCents == onCheck.grossCents.map { $0 - 8000 })
        #expect(atClose.tipsAlreadyPaidCents == 8000)
    }

    @Test("a share alone makes the tips line auditable")
    func shareAloneIsAuditable() throws {
        let day = CivilDay(iso: "2026-10-05")!
        let shift = ShiftInput(id: UUID(), workDay: day, tipOutCents: 4000, tipShareInCents: 18000)
        let snapshot = try EarningsSnapshot.build(
            EarningsInputs(shifts: [shift], paychecks: [], schedule: nil, rates: [], calendars: [], asOf: .distantFuture))
        let expectation = PaycheckReconciler.Expectation(
            result: snapshot.range(DayRange(start: day, end: day)), stamp: snapshot.stamp)
        #expect(expectation.auditableTipsLineCents == 14000)
    }
}
