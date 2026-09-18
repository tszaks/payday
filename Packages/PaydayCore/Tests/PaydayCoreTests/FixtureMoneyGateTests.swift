import Foundation
import Testing
@testable import PaydayCore

/// Money gates for the six fixtures whose money gated nothing.
///
/// ## How these six were found
///
/// Criterion 3 is "all 14 golden fixtures pass against the real production
/// engine, never a test helper". `FixtureGateTests` closed that for N1, N2,
/// N3 and E1, whose expected values had been asserted from literals in the
/// language where the engine lives rather than read out of the `.json`.
///
/// Nobody had measured the other ten. MEASURED on 2026-09-18 by mutation:
/// bump EVERY `*Cents` value under a fixture's `expected` block and re-run
/// `swift test --package-path Packages/PaydayCore`. Eight fixtures failed, as
/// they should. Six did not:
///
/// ```
/// W3 UNGATED (45 cents fields moved)   P1 UNGATED (12)
/// M1 UNGATED (11)                      S2 UNGATED (31)
/// H1 UNGATED  (5)                      C1 UNGATED (37)
/// ```
///
/// 141 money values, changeable with the suite still reporting
/// `Test run with 246 tests in 31 suites passed`. Hand-verified on C1 with a
/// deliberately large delta (+1000, to rule out a rounding tolerance): the
/// test named "partial: C1's week reports missingHours 1 and a known total of
/// 10330" passed with every cents value in `C1.json` moved, because that
/// `10330` is a literal in Swift and not read from the file.
///
/// The distinction that matters, because it bounds how bad this was. The
/// engine's numbers were still asserted and still correct; what was missing is
/// that the FIXTURE gated them. So the files could drift away from what the
/// engine is actually checked against, in silence, and an edit to one would
/// fail nothing. Same family as a lint printing `[PASS]` after a dropped `fi`.
///
/// Only mutation found this. Reading the fixtures and reading the tests both
/// looked fine, which is the argument for treating a gate as unproven until it
/// has failed on purpose at least once.
///
/// ## What this gate found on its first run
///
/// A wrong number inside one of the six. `C1.json`'s hours-missing shift
/// (004) declared `regularMinutes: 0` and `overtimeMinutes: 0` while
/// declaring `minutesWorked: null` two keys earlier -- self-contradictory,
/// and conflating "no hours were logged" with "zero minutes fell under the
/// threshold". `ShiftValuation` documents the engine's answer explicitly:
/// those fields are "nil when there is nothing to split: no hours logged, or
/// no calendar policy in effect to define a workweek."
///
/// The fixture was corrected rather than the test loosened, because the
/// engine's behaviour is the documented one and the fixture contradicted
/// itself. Swept all 14 for the same shape first; C1 was the only one. It was
/// reachable only because nothing had ever read those fields -- which is the
/// point: six fixtures gated no money, and inside one of them sat a figure no
/// test could see.
///
/// ## What these tests do
///
/// Each reads BOTH sides out of the fixture and puts the real engine in
/// between, so the file is the source of truth and a drift in either direction
/// fails.
@Suite("Fixture money gates")
struct FixtureMoneyGateTests {

    /// One shift's declared money, from either spelling a fixture uses.
    ///
    /// The fixtures grew independently and say the same things two ways: a
    /// nested `components` object with unsuffixed keys (`cash`, `regularWages`)
    /// and flat suffixed keys (`regularWagesCents`). Reading both means the
    /// gate covers what each file actually declares instead of forcing six
    /// files to be rewritten into one shape, which would be a much larger and
    /// riskier diff for no gain in coverage.
    private struct Declared {
        var cash: Int?
        var credit: Int?
        var gratuityFees: Int?
        var tipOut: Int?
        var regularWages: Int?
        var overtimeWages: Int?
        var nonWageEarnings: Int?
        var earnedIncome: Int?

        /// Every money value this object actually declared, so a test can
        /// refuse to pass on a fixture that declared none.
        var count: Int {
            [cash, credit, gratuityFees, tipOut,
             regularWages, overtimeWages, nonWageEarnings, earnedIncome]
                .compactMap { $0 }.count
        }

        init(_ object: [String: JSONValue]) {
            let components = object["components"]?.objectValue ?? [:]
            cash = components["cash"]?.intValue ?? object["cashCents"]?.intValue
            credit = components["credit"]?.intValue ?? object["creditCents"]?.intValue
            gratuityFees = components["gratuityFees"]?.intValue
                ?? object["gratuityFeesCents"]?.intValue
            tipOut = components["tipOut"]?.intValue ?? object["tipOutCents"]?.intValue
            regularWages = components["regularWages"]?.intValue
                ?? object["regularWagesCents"]?.intValue
            overtimeWages = components["overtimeWages"]?.intValue
                ?? object["overtimeWagesCents"]?.intValue
            nonWageEarnings = object["nonWageEarningsCents"]?.intValue
            earnedIncome = object["earnedIncomeCents"]?.intValue
        }

        /// Named field by field so a failure says WHICH figure drifted, not
        /// merely that two component structs differ.
        func check(against actual: EarningsComponents, _ label: String) {
            if let cash { #expect(actual.voluntaryCashCents == cash, "\(label) cash") }
            if let credit { #expect(actual.voluntaryCreditCents == credit, "\(label) credit") }
            if let gratuityFees {
                #expect(actual.gratuityFeesCents == gratuityFees, "\(label) gratuityFees")
            }
            if let tipOut { #expect(actual.tipOutCents == tipOut, "\(label) tipOut") }
            if let regularWages {
                #expect(actual.regularWagesCents == regularWages, "\(label) regularWages")
            }
            if let overtimeWages {
                #expect(actual.overtimeWagesCents == overtimeWages, "\(label) overtimeWages")
            }
            if let nonWageEarnings {
                #expect(actual.nonWageEarningsCents == nonWageEarnings, "\(label) nonWageEarnings")
            }
            if let earnedIncome {
                #expect(actual.earnedIncomeCents == earnedIncome, "\(label) earnedIncome")
            }
        }
    }

    /// The ledger's own answer for a fixture, keyed by shift id.
    ///
    /// `CompensationLedger.evaluate` rather than an `EarningsSnapshot` query,
    /// deliberately: S2's whole point is a future-dated shift that the LEDGER
    /// values and a to-date QUERY excludes, so its
    /// `ledgerValuationOfFutureShift` block can only be checked against the
    /// ledger. Using one engine entry point for all five keeps the gate from
    /// asking a different question of S2 than of the others.
    private func valuations(_ fixture: Fixture) throws -> [UUID: ShiftValuation] {
        let output = CompensationLedger.evaluate(
            try fixture.toShiftInputs(),
            rates: fixture.toRatePolicies(),
            calendars: try fixture.toCalendarPolicies()
        )
        return Dictionary(output.valuations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - The per-shift fixtures

    /// W3, C1 and S2 declare per-shift money; every declared figure must be
    /// what the real ledger computes for that shift.
    ///
    /// - W3: the `firstWeekday` fixture. Its money must be W2's, which is the
    ///   whole claim ("changing the calendar grid moves nothing"), so gating
    ///   its cents is gating that claim.
    /// - C1: the partial-completeness fixture, one shift with null minutes.
    /// - S2: the as-of fixture, including the future shift the query excludes.
    @Test(
        "every per-shift money value these fixtures declare is the real ledger's",
        arguments: ["W3", "C1", "S2"]
    )
    func perShiftMoneyIsLedgerTruth(_ id: String) throws {
        let fixture = try FixtureLoader.load(id)
        let byID = try valuations(fixture)

        // `perShift` for W3 and C1; a single `ledgerValuationOfFutureShift`
        // for S2. Both are lists of objects carrying an `id`.
        var declaredShifts: [[String: JSONValue]] = []
        if let perShift = fixture.expected["perShift"]?.arrayValue {
            declaredShifts = perShift.compactMap { $0.objectValue }
        }
        if let single = fixture.expected["ledgerValuationOfFutureShift"]?.objectValue {
            declaredShifts.append(single)
        }
        #expect(!declaredShifts.isEmpty, "\(id).json must declare per-shift money")

        var checked = 0
        for object in declaredShifts {
            let shiftID = try #require(
                object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                "\(id): a declared shift has no id"
            )
            let valuation = try #require(
                byID[shiftID],
                "\(id): the ledger produced no valuation for \(shiftID)"
            )
            let declared = Declared(object)
            declared.check(against: valuation.components, "\(id)/\(shiftID)")
            checked += declared.count

            // Minutes too, where declared: a fixture whose money is right for
            // the wrong duration is still wrong, and `minutesWorked` was the
            // field my first, mis-aimed sweep perturbed.
            if let minutes = object["minutesWorked"]?.intValue {
                #expect(valuation.minutesWorked == minutes, "\(id)/\(shiftID) minutesWorked")
            }
            if let regular = object["regularMinutes"]?.intValue {
                #expect(valuation.regularMinutes == regular, "\(id)/\(shiftID) regularMinutes")
            }
            if let overtime = object["overtimeMinutes"]?.intValue {
                #expect(valuation.overtimeMinutes == overtime, "\(id)/\(shiftID) overtimeMinutes")
            }
        }

        // The gate must not pass by checking nothing, which is the exact
        // failure it was written to fix.
        #expect(checked > 0, "\(id): no money value was actually compared")
    }

    /// H1 keys its valuations by uuid STRING rather than by an array, because
    /// its claim is about which shifts are excluded from both sides of $/hr.
    @Test("H1's per-shift money is the real ledger's")
    func h1MoneyIsLedgerTruth() throws {
        let fixture = try FixtureLoader.load("H1")
        let byID = try valuations(fixture)
        let declaredMap = try #require(
            fixture.expected["shiftValuations"]?.objectValue,
            "H1.json must declare shiftValuations"
        )
        #expect(!declaredMap.isEmpty)

        var checked = 0
        for (key, value) in declaredMap {
            guard let object = value.objectValue else { continue }
            let shiftID = try #require(UUID(uuidString: key), "H1: \(key) is not a uuid")
            let valuation = try #require(byID[shiftID], "H1: no valuation for \(shiftID)")
            let declared = Declared(object)
            declared.check(against: valuation.components, "H1/\(shiftID)")
            checked += declared.count
            // H1's second shift declares null minutes on purpose; comparing
            // Optionals directly keeps that case honest rather than defaulting
            // it to zero, which would make "no hours logged" and "zero hours
            // logged" the same fact.
            #expect(valuation.minutesWorked == object["minutesWorked"]?.intValue,
                    "H1/\(shiftID) minutesWorked")
        }
        #expect(checked > 0, "H1: no money value was actually compared")
    }

    /// M1 declares per-DAY money plus the chart point for that day, and its
    /// claim is that the two are the same number.
    @Test("M1's per-day money is the real ledger summed over that day, and equals its chart point")
    func m1DayMoneyIsLedgerTruth() throws {
        let fixture = try FixtureLoader.load("M1")
        let output = CompensationLedger.evaluate(
            try fixture.toShiftInputs(),
            rates: fixture.toRatePolicies(),
            calendars: try fixture.toCalendarPolicies()
        )
        let days = try #require(fixture.expected["days"]?.arrayValue, "M1.json must declare days")
        #expect(!days.isEmpty)

        var checked = 0
        for entry in days {
            guard let object = entry.objectValue else { continue }
            let day = try #require(
                object["workDay"]?.stringValue.flatMap(CivilDay.init(iso:)),
                "M1: a declared day has no workDay"
            )
            let onThatDay = output.valuations.filter { $0.workDay == day }
            #expect(!onThatDay.isEmpty, "M1: the ledger values nothing on \(day)")
            let total = onThatDay.reduce(EarningsComponents.zero) { $0 + $1.components }

            let declared = Declared(object)
            declared.check(against: total, "M1/\(day)")
            checked += declared.count

            // [M1] itself: the chart point IS the day total. Declared as its
            // own key so the fixture could contradict itself; this is what
            // stops that.
            if let chartPoint = object["chartPointCents"]?.intValue {
                #expect(total.earnedIncomeCents == chartPoint, "M1/\(day) chartPointCents")
                checked += 1
            }

            let minutes = onThatDay.compactMap(\.minutesWorked).reduce(0, +)
            if let declaredMinutes = object["minutesWorked"]?.intValue {
                #expect(minutes == declaredMinutes, "M1/\(day) minutesWorked")
            }
        }
        #expect(checked > 0, "M1: no money value was actually compared")
    }

    // MARK: - P1, the paycheck fixture

    /// P1's claim is not a ledger figure at all: it is that an inferred
    /// correction is offered as a PROPOSAL and never written over what the
    /// person entered. So the gate runs the real `PaycheckReconciler` over the
    /// fixture's own observed figures.
    ///
    /// Every number and the label come out of the file, so P1 can no longer
    /// declare a correction the reconciler would not produce, or a label with
    /// the wrong figure in it.
    @Test("P1's proposal is what the real reconciler infers, and the observed stub is untouched")
    func p1ProposalIsReconcilerTruth() throws {
        let fixture = try FixtureLoader.load("P1")
        let expected = fixture.expected

        let observedTips = try #require(expected["observedPaidTipsCents"]?.intValue)
        let observedRegular = try #require(expected["observedRegularWagesCents"]?.intValue)
        let observedOvertime = expected["observedOvertimeWagesCents"]?.intValue
        let observedGratuity = expected["observedGratuityCents"]?.intValue
        let observedGross = try #require(expected["observedGrossPayCents"]?.intValue)

        let observation = PaycheckReconciler.Observation(
            paidTipsCents: observedTips,
            regularWagesCents: observedRegular,
            overtimeWagesCents: observedOvertime,
            gratuityCents: observedGratuity,
            grossCents: observedGross
        )

        let declared = try #require(
            expected["proposedPaidTipsCorrection"]?.objectValue,
            "P1.json must declare its proposal"
        )

        if declared["present"]?.boolValue == true {
            let proposal = try #require(
                PaycheckReconciler.proposal(for: observation),
                "P1 declares a proposal but the real reconciler infers none"
            )
            #expect(proposal.proposedCents == declared["inferredTipsCents"]?.intValue,
                    "P1 inferredTipsCents")
            #expect(proposal.correctionCents == declared["correctionCents"]?.intValue,
                    "P1 correctionCents")
            // The registry's only allowed label for this metric, with the
            // figure substituted by the real formatter. A fixture cannot
            // declare "$100.50" for a proposal of a different amount.
            #expect(proposal.label == declared["label"]?.stringValue, "P1 label")
            // The observed side is unchanged BY the proposal existing. This is
            // the actual defect P1 exists to prevent: the editor used to open
            // on `reconciledPaidTipsCents`, so opening the sheet and tapping
            // Save wrote the inference over the stub.
            #expect(proposal.observedCents == observedTips, "P1 observedCents")
        } else {
            #expect(PaycheckReconciler.proposal(for: observation) == nil,
                    "P1 declares no proposal but the real reconciler infers one")
        }

        // The declared "still the stub afterwards" values must all equal the
        // observed stub, or the fixture is asserting the very rewrite it was
        // written to forbid.
        for key in [
            "observedPaidTipsCentsAfterProposal",
            "storedPaidTipsCentsAfterEditorOpenAndSave",
            "storedPaidTipsCentsAfterScanPrefill",
            "apiPaidTipsCents",
            "reconciliationObservedTipsSideCents",
        ] {
            if let value = expected[key]?.intValue {
                #expect(value == observedTips, "P1 \(key) must still be the entered stub")
            }
        }

        // And the wrong answers stay wrong: P1 names the auto-applied value
        // explicitly so a regression that starts substituting it fails here
        // rather than silently agreeing with the fixture.
        if let wrong = expected["wrongAnswers"]?.objectValue,
           let autoApplied = wrong["reconciledPaidTipsCentsAutoApplied"]?.intValue {
            #expect(autoApplied != observedTips,
                    "P1's wrong answer must differ from the right one, or it proves nothing")
        }
    }
}
