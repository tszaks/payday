import Foundation
import Testing
@testable import PaydayCore

/// The uploadable document must not disagree with the engine that produced
/// it. That is the whole project thesis applied to one type, so it is
/// asserted against EVERY range over the fixtures rather than a few
/// hand-picked ones.
@Suite("Snapshot document")
struct SnapshotDocumentTests {

    /// Not every fixture declares an `asOf`; the ones that do not are
    /// settled spans. Falling back to the last work day keeps them in the
    /// sweep instead of silently dropping them.
    ///
    /// The first version threw `FixtureLoader.Error.missing(id:)` here, which
    /// reported "Fixture W1.json is not in Tests/PaydayCoreTests/Fixtures"
    /// about a file that exists. Reusing an error for a second meaning makes
    /// the message lie about the cause.
    private func snapshot(_ id: String) throws -> EarningsSnapshot {
        let fixture = try FixtureLoader.load(id)
        let cutoff = fixture.asOf
            ?? fixture.toShiftInputs().map(\.workDay).max()
            ?? CivilDay(year: 2026, month: 12, day: 31)
        return try EarningsSnapshot.build(
            EarningsInputs(
                shifts: fixture.toShiftInputs(),
                paychecks: try fixture.toPaycheckInputs(),
                schedule: fixture.toScheduleInput(),
                rates: fixture.toRatePolicies(),
                calendars: try fixture.toCalendarPolicies(),
                asOf: cutoff
            ),
            generation: 1,
            computedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// **The gate.** For every fixture, and every range from one day to the
    /// whole span, summing the document's days must equal what the engine
    /// answers for that range.
    ///
    /// Exhaustive rather than sampled: the fixtures are small enough that
    /// every (start, end) pair is affordable, and a sampled version would
    /// have to justify which ranges it skipped. The boundary ranges are the
    /// ones that have historically been wrong -- a period straddling a
    /// workweek lost its overtime, and a month-first fold lost $11.31.
    @Test("the document matches the engine on every range")
    func documentMatchesTheEngineOnEveryRange() throws {
        var rangesChecked = 0
        for id in FixtureLoader.availableIDs() {
            guard let snap = try? snapshot(id), !snap.shifts.isEmpty else { continue }
            let doc = SnapshotDocument(snap)
            let workDays = snap.shifts.map(\.workDay).sorted()
            guard let first = workDays.first, let last = workDays.last else { continue }

            let span = DayRange(start: first, end: last).days
            for (i, start) in span.enumerated() {
                for end in span[i...] {
                    let r = DayRange(start: start, end: end)
                    let engine = snap.range(r)
                    let document = doc.range(r)
                    rangesChecked += 1

                    #expect(document.knownComponents == engine.knownComponents,
                            "\(id) \(start)...\(end) knownComponents")
                    #expect(document.coveredComponents == engine.coveredComponents,
                            "\(id) \(start)...\(end) coveredComponents")
                    #expect(document.minutes == engine.minutes,
                            "\(id) \(start)...\(end) minutes")
                    #expect(document.regularMinutes == engine.regularMinutes,
                            "\(id) \(start)...\(end) regularMinutes")
                    #expect(document.overtimeMinutes == engine.overtimeMinutes,
                            "\(id) \(start)...\(end) overtimeMinutes")
                    #expect(document.totalShifts == engine.completeness.totalShifts,
                            "\(id) \(start)...\(end) totalShifts")
                    #expect(document.shiftsWageValued == engine.completeness.shiftsWageValued,
                            "\(id) \(start)...\(end) shiftsWageValued")
                }
            }
        }
        #expect(rangesChecked > 100,
                "the sweep must actually run; checked \(rangesChecked)")
    }

    /// A day the engine has no shift for is omitted from the payload, and an
    /// omitted day must still read as zero rather than as missing.
    @Test("an omitted empty day sums to zero, not to nothing")
    func emptyDaysAreZeroNotMissing() throws {
        let snap = try snapshot("W1")
        let doc = SnapshotDocument(snap)
        let far = DayRange(start: CivilDay(year: 2000, month: 1, day: 1),
                           end: CivilDay(year: 2000, month: 1, day: 31))
        #expect(doc.range(far) == SnapshotDocument.Total.zero)
        #expect(doc.days.allSatisfy { $0.totalShifts > 0 },
                "only days carrying a shift are emitted")
    }

    /// The payload is stored as jsonb and read by a Deno test and by
    /// `/v1/summary`, so it has to survive a round trip byte-for-byte in
    /// MEANING, and its day order has to be stable or two devices computing
    /// the same data would upload different bytes.
    @Test("the document round-trips and is order-stable")
    func roundTripsAndIsOrdered() throws {
        let snap = try snapshot("W2")
        let doc = SnapshotDocument(snap)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(SnapshotDocument.self, from: data)
        #expect(back == doc)
        #expect(doc.days.map(\.day) == doc.days.map(\.day).sorted(),
                "days ascending, so two devices produce identical bytes")

        let shuffled = SnapshotDocument(
            engineVersion: doc.engineVersion, asOf: doc.asOf,
            manifestDigest: doc.manifestDigest,
            wageFeatureEnabled: doc.wageFeatureEnabled,
            days: doc.days.reversed())
        #expect(shuffled == doc, "the initializer sorts, so input order cannot leak")
    }

    /// The schema version is what lets a reader refuse a document it does not
    /// understand instead of misreading one.
    @Test("the document states its schema version")
    func statesItsSchemaVersion() throws {
        let doc = SnapshotDocument(try snapshot("W1"))
        #expect(doc.schemaVersion == 1)
        #expect(doc.schemaVersion == SnapshotDocument.currentSchemaVersion)
    }
}
