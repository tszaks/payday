import Foundation
import Testing
@testable import PaydayCore

/// Turns four fixture FILES into four fixture GATES.
///
/// Criterion 3 is "all 14 golden fixtures pass against the real production
/// engine, never a test helper." Measured on 2026-09-18, that was true in
/// substance for all 14 — but for N1, N2, N3 and E1 the expected values were
/// asserted in the language where the engine lives (SQL for the deriver,
/// Swift for the CSV exporter) rather than read out of the `.json`. So those
/// four files documented an expectation and gated nothing: editing
/// `N2.json`'s gratuity from 500 to anything else would have failed no test.
///
/// That is the same false-signal family as a lint printing `[PASS]` after a
/// dropped `fi`, or a mutation test whose mutation silently never applied:
/// an artifact that looks authoritative while checking nothing. "Met as
/// written" is not the bar; the bar is that the artifact cannot drift in
/// silence.
///
/// Each assertion below reads BOTH sides from the fixture and puts the real
/// engine in between, so the fixture is the source of truth and a drift in
/// either direction fails.
@Suite("Fixture gates")
struct FixtureGateTests {

    /// The migration fixtures declare an EMPTY `shifts` array on purpose:
    /// their input is `legacyEntries` and their output is the conversion
    /// result under `expected`. So `toShiftInputs()` yields nothing for them,
    /// and the gate has to feed the DECLARED conversion result through the
    /// real ledger and check the declared money against it.
    ///
    /// What that gates: an edit to the declared shift record, or to the
    /// declared components, or a change in the ledger, now fails. What it does
    /// NOT gate is the conversion itself — `legacyEntries` to shift records is
    /// `private.derive_shifts`, asserted in
    /// `supabase/tests/shift_deriver_test.sql`, which names N1, N2 and N3
    /// explicitly. Two halves, two owners, both covered; this file is not
    /// pretending to cover the SQL half.
    @Test("N1, N2 and N3's declared money is what the real ledger computes from their declared shift",
          arguments: ["N1", "N2", "N3"])
    func migrationFixtureComponentsAreEngineTruth(_ id: String) throws {
        let fixture = try FixtureLoader.load(id)

        // N1 and N3 call it `shiftRecords`; N2 calls it `migratedShifts`.
        let records = try #require(
            (fixture.expected["shiftRecords"] ?? fixture.expected["migratedShifts"])?.arrayValue,
            "\(id).json must declare its conversion result"
        )
        #expect(!records.isEmpty)

        let inputs: [ShiftInput] = try records.map { record in
            let rid = try #require(record["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let day = try #require(record["workDay"]?.stringValue.flatMap(CivilDay.init(iso:)))
            return ShiftInput(
                id: rid,
                workDay: day,
                voluntaryCashCents: record["cashTipsCents"]?.intValue ?? 0,
                voluntaryCreditCents: record["creditTipsCents"]?.intValue ?? 0,
                gratuityFeesCents: record["gratuityFeesCents"]?.intValue ?? 0,
                tipOutCents: record["tipOutCents"]?.intValue,
                minutesWorked: record["minutesWorked"]?.intValue
            )
        }

        let output = CompensationLedger.evaluate(
            inputs,
            rates: fixture.toRatePolicies(),
            calendars: try fixture.toCalendarPolicies()
        )
        #expect(output.valuations.count == records.count)

        // N1 and N3 declare per-valuation components; N2 declares one
        // top-level `components` for its single shift. Summing the output
        // handles both without special-casing.
        let declared = try #require(
            fixture.expected["components"]?.objectValue
                ?? fixture.expected["valuations"]?.arrayValue?.first?["components"]?.objectValue,
            "\(id).json must declare components"
        )
        let total = output.valuations.reduce(EarningsComponents.zero) { $0 + $1.components }

        // Named field by field so a failure says WHICH figure drifted.
        #expect(total.voluntaryCashCents == declared["cashCents"]?.intValue, "\(id) cashCents")
        #expect(total.voluntaryCreditCents == declared["creditCents"]?.intValue, "\(id) creditCents")
        #expect(total.gratuityFeesCents == declared["gratuityFeesCents"]?.intValue, "\(id) gratuityFeesCents")
        #expect(total.tipOutCents == declared["tipOutCents"]?.intValue, "\(id) tipOutCents")
        #expect(total.regularWagesCents == declared["regularWagesCents"]?.intValue, "\(id) regularWagesCents")
        #expect(total.overtimeWagesCents == declared["overtimeWagesCents"]?.intValue, "\(id) overtimeWagesCents")

        // And the derived totals the fixture also declares, where it does, so
        // an edit cannot leave the file self-contradictory.
        if let nonWage = declared["nonWageEarningsCents"]?.intValue {
            #expect(total.nonWageEarningsCents == nonWage, "\(id) nonWageEarningsCents")
        }
        if let earned = declared["earnedIncomeCents"]?.intValue {
            #expect(total.earnedIncomeCents == earned, "\(id) earnedIncomeCents")
        }
    }

    /// E1 is the export fixture, and its whole point is that hours are exact
    /// minutes rather than the quarter-hour rounding the shipped CSV used.
    /// Both the minute count and the rendered strings come out of the file,
    /// with the real `HoursFormatting` in between.
    @Test("E1's hour strings are what the real formatter produces from its own minutes")
    func e1HourStringsAreEngineTruth() throws {
        let fixture = try FixtureLoader.load("E1")
        let minutes = try #require(fixture.expected["minutesWorked"]?.intValue)
        let hours = try #require(fixture.expected["hours"]?.objectValue)

        let decimal = try #require(hours["decimalFourPlaces"]?.stringValue)
        let clock = try #require(hours["clock"]?.stringValue)

        #expect(HoursFormatting.decimalHours(minutes: minutes) == decimal)
        #expect(HoursFormatting.clockHours(minutes: minutes) == clock)

        // The adapter round trip: the legacy Double the app stored must come
        // back as exactly these minutes. This is the half that was uncovered
        // when the CSV was rounding to quarter hours.
        let roundTrip = try #require(fixture.expected["adapterRoundTrip"]?.objectValue)
        let legacyDouble = try #require(roundTrip["legacyHoursWorkedDouble"]?.doubleValue)
        let roundTripMinutes = try #require(roundTrip["minutesWorked"]?.intValue)
        #expect(HoursFormatting.minutes(fromHours: legacyDouble) == roundTripMinutes)
        #expect(roundTripMinutes == minutes)

        // And the CSV cells the exporter writes are the same two strings, so
        // the fixture cannot declare one thing for the column and another for
        // the hours block.
        let csvRow = try #require(fixture.expected["csvRow"]?.objectValue)
        #expect(csvRow["decimalHoursCell"]?.stringValue == decimal)
        #expect(csvRow["clockHoursCell"]?.stringValue == clock)

        // Internal arithmetic consistency of the declared money, so an edit to
        // one cell cannot leave the fixture self-contradictory.
        let nonWage = try #require(fixture.expected["nonWageEarningsCents"]?.intValue)
        let regular = try #require(fixture.expected["regularWagesCents"]?.intValue)
        let overtime = try #require(fixture.expected["overtimeWagesCents"]?.intValue)
        let earned = try #require(fixture.expected["earnedIncomeCents"]?.intValue)
        #expect(nonWage + regular + overtime == earned)
    }
}
