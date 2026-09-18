import Foundation
import Testing
@testable import PaydayCore

/// Pins the `paydaycore-manifest-v1` contract. The canonical fixture below is
/// built so every ordering and formatting rule in the format doc comment is
/// exercised by at least one record whose insertion order, id order and date
/// order all disagree with each other:
///
/// - shifts: `shiftC` sorts AFTER `shiftB` by id but has the EARLIEST
///   `workDay`, so the encoding is proven to sort by id, not by date.
/// - `shiftA.recordedAt` is `1_790_000_000.9`; the line must read
///   `1790000000` (truncation toward zero, not rounding).
/// - rates: `rateLate` is inserted FIRST and its id sorts BEFORE `rate1`, but
///   its `effectiveFrom` is later, so it must be encoded SECOND (effectiveFrom
///   beats both id and insertion order).
/// - calendars: `calendarTie` shares `calendar1`'s `effectiveFrom`, is inserted
///   SECOND, and has the smaller id, so it must be encoded FIRST (id is the
///   tiebreak).
/// - the policies section writes every rate line before any calendar line.
@Suite("InputManifest")
struct InputManifestTests {
    // Fixed UUIDs so the canonical text below is reproducible.
    static let shiftA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let shiftB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    /// Sorts after shiftB by id; its workDay is earlier than shiftA's.
    static let shiftC = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    static let paycheck1 = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let rate1 = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    /// Sorts before rate1 by id; its effectiveFrom is later.
    static let rateLate = UUID(uuidString: "0AAAAAAA-0AAA-4AAA-8AAA-0AAAAAAAAAAA")!
    static let calendar1 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    /// Same effectiveFrom as calendar1; smaller id.
    static let calendarTie = UUID(uuidString: "55555555-5555-4555-8555-555555555500")!

    static let shifts: [ShiftInput] = [
        ShiftInput(id: shiftA, workDay: CivilDay(year: 2026, month: 9, day: 28), period: .dinner,
                   // Fractional seconds: the encoding truncates toward zero, so this must read 1790000000.
                   recordedAt: Date(timeIntervalSince1970: 1_790_000_000.9),
                   voluntaryCashCents: 6000, voluntaryCreditCents: 4000, gratuityFeesCents: 0,
                   tipOutCents: 1000, minutesWorked: 255),
        ShiftInput(id: shiftB, workDay: CivilDay(year: 2026, month: 9, day: 29), period: nil,
                   recordedAt: nil,
                   voluntaryCashCents: 0, voluntaryCreditCents: 12345, gratuityFeesCents: 500,
                   tipOutCents: nil, minutesWorked: nil),
        ShiftInput(id: shiftC, workDay: CivilDay(year: 2026, month: 9, day: 21), period: .lunch,
                   recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
                   voluntaryCashCents: 2500, voluntaryCreditCents: 0, gratuityFeesCents: 0,
                   tipOutCents: 0, minutesWorked: 240),
    ]

    static let paychecks: [PaycheckInput] = [
        PaycheckInput(id: paycheck1, periodStart: CivilDay(year: 2026, month: 9, day: 21),
                      periodEnd: CivilDay(year: 2026, month: 9, day: 27), paidTipsCents: 10000,
                      grossPayCents: 15050, netPayCents: nil, regularWagesCents: 5000,
                      overtimeWagesCents: 0, gratuityCents: 0, taxesCents: nil),
    ]

    static let schedule = PayScheduleInput(frequency: "weekly", anchorPeriodEnd: CivilDay(year: 2026, month: 9, day: 27),
                                           payDelayDays: 5, firstWeekday: 2)

    /// Insertion order is deliberately the reverse of the canonical order.
    static let rates: [PayRatePolicy] = [
        PayRatePolicy(id: rateLate, effectiveFrom: CivilDay(year: 2026, month: 7, day: 6), hourlyRateCents: 300,
                      provenance: .assumedFromLegacySetting),
        PayRatePolicy(id: rate1, effectiveFrom: CivilDay(year: 2026, month: 1, day: 1), hourlyRateCents: 283, provenance: .confirmed),
    ]

    /// Insertion order is deliberately the reverse of the canonical order.
    static let calendars: [PayrollCalendarPolicy] = [
        PayrollCalendarPolicy(id: calendar1, effectiveFrom: CivilDay(year: 2026, month: 1, day: 5), workweekStartWeekday: 2,
                              payrollTimeZone: TimeZone(identifier: "America/New_York")!),
        PayrollCalendarPolicy(id: calendarTie, effectiveFrom: CivilDay(year: 2026, month: 1, day: 5), workweekStartWeekday: 1,
                              payrollTimeZone: TimeZone(identifier: "America/Chicago")!),
    ]

    static let asOf = CivilDay(year: 2026, month: 10, day: 2)

    static func manifest(
        shifts: [ShiftInput] = shifts, paychecks: [PaycheckInput] = paychecks,
        schedule: PayScheduleInput? = schedule, rates: [PayRatePolicy] = rates,
        calendars: [PayrollCalendarPolicy] = calendars, asOf: CivilDay? = asOf
    ) throws -> InputManifest {
        try InputManifest(shifts: shifts, paychecks: paychecks, schedule: schedule, rates: rates, calendars: calendars, asOf: asOf)
    }

    /// The ENCODER's output for the canonical fixture. Every ordering test
    /// reads this, never the `canonicalText` literal below: parsing the
    /// hand-written literal asserts only that the literal is sorted, so it
    /// stays green no matter how the encoder sorts. Only
    /// `canonicalTextMatches` compares the two.
    static func encodedText() throws -> String {
        try InputManifest.canonicalText(
            shifts: shifts, paychecks: paychecks, schedule: schedule,
            rates: rates, calendars: calendars, asOf: asOf
        )
    }

    // MARK: Section texts (the sub-digest inputs, written out by hand)

    static let prefix = "paydaycore-manifest-v1\n"

    static let shiftsSection = prefix + """
    S|11111111-1111-4111-8111-111111111111|2026-09-28|dinner|1790000000|6000|4000|0|1000|255
    S|22222222-2222-4222-8222-222222222222|2026-09-29|-|-|0|12345|500|0|-
    S|99999999-9999-4999-8999-999999999999|2026-09-21|lunch|1780000000|2500|0|0|0|240
    """

    static let paychecksSection = prefix + """
    P|33333333-3333-4333-8333-333333333333|2026-09-21|2026-09-27|10000|15050|-|5000|0|0|-
    """

    static let scheduleSection = prefix + "schedule|weekly|2026-09-27|5|2"

    /// Rates first, then calendars. Rates by effectiveFrom (rate1 2026-01-01
    /// before rateLate 2026-07-06 despite rateLate's smaller id); calendars by
    /// id on the effectiveFrom tie (…500 before …555).
    static let policiesSection = prefix + """
    R|44444444-4444-4444-8444-444444444444|2026-01-01|283|confirmed
    R|0AAAAAAA-0AAA-4AAA-8AAA-0AAAAAAAAAAA|2026-07-06|300|assumedFromLegacySetting
    C|55555555-5555-4555-8555-555555555500|2026-01-05|1|2400|150|America/Chicago
    C|55555555-5555-4555-8555-555555555555|2026-01-05|2|2400|150|America/New_York
    """

    /// The exact bytes the pinned digest is computed over. This is the
    /// `paydaycore-manifest-v1` contract: if this text changes, every stored
    /// digest changes, and the format version must be bumped.
    static let canonicalText = """
    paydaycore-manifest-v1
    engine|1
    asOf|2026-10-02
    shifts|3
    S|11111111-1111-4111-8111-111111111111|2026-09-28|dinner|1790000000|6000|4000|0|1000|255
    S|22222222-2222-4222-8222-222222222222|2026-09-29|-|-|0|12345|500|0|-
    S|99999999-9999-4999-8999-999999999999|2026-09-21|lunch|1780000000|2500|0|0|0|240
    paychecks|1
    P|33333333-3333-4333-8333-333333333333|2026-09-21|2026-09-27|10000|15050|-|5000|0|0|-
    schedule|weekly|2026-09-27|5|2
    rates|2
    R|44444444-4444-4444-8444-444444444444|2026-01-01|283|confirmed
    R|0AAAAAAA-0AAA-4AAA-8AAA-0AAAAAAAAAAA|2026-07-06|300|assumedFromLegacySetting
    calendars|2
    C|55555555-5555-4555-8555-555555555500|2026-01-05|1|2400|150|America/Chicago
    C|55555555-5555-4555-8555-555555555555|2026-01-05|2|2400|150|America/New_York
    """

    /// SHA-256 of `canonicalText`, computed with `shasum -a 256` over the
    /// same bytes and pasted. Do not "fix" a mismatch here by re-pinning: a
    /// mismatch means the encoding changed.
    ///
    /// Re-pinned once, deliberately, on 2026-09-18, when `tipOutCents` was
    /// canonicalized to `?? 0`. The only byte that moved in `canonicalText`
    /// is shift `2222...`'s tip-out field, `-` to `0`. The new hex was
    /// DERIVED, not copied out of the failing assertion: the contract literal
    /// was extracted and hashed with `shasum -a 256` independently, and that
    /// external hash agrees with what the encoder produces. A hex pasted from
    /// the code's own output would only prove the code equals itself.
    static let pinnedDigest = "d359073164e7dfac00264936c65a17e1b156cf90a23660b690d463b289656cda"

    /// The pair that must be read together, so neither half looks like a bug.
    ///
    /// The VALUE keeps nil and 0 apart: `ShiftRecord.tipOutCents` is an
    /// `Int?`, the record genuinely carries "was tip-out entered", and
    /// `ShiftInput` preserves it. The DIGEST collapses them, because the
    /// digest answers only "would this change the valued output", and
    /// `EarningsComponents.tipOutCents` is a non-optional Int defaulting to
    /// 0 -- so the engine cannot tell them apart and neither should its
    /// change-detector.
    ///
    /// Before canonicalization these two were inconsistent: the digest was
    /// finer-grained than the computation it guards, so one shift fingerprinted
    /// differently depending on whether it was read through
    /// `ShiftInputAdapter` or `LegacySnapshotBridge` -- a false "changed"
    /// signal for inputs that value identically.
    @Test("nil and zero tip-out are distinct as values and identical as digests")
    func tipOutNilAndZeroAreDistinctValuesWithOneDigest() throws {
        let day = CivilDay(iso: "2026-09-28")!
        func shift(_ tipOut: Int?) -> ShiftInput {
            ShiftInput(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                workDay: day,
                voluntaryCashCents: 6_000,
                voluntaryCreditCents: 4_000,
                tipOutCents: tipOut,
                minutesWorked: 255
            )
        }
        let unentered = shift(nil)
        let explicitZero = shift(0)

        // Distinct as values: the fidelity is kept.
        #expect(unentered.tipOutCents == nil)
        #expect(explicitZero.tipOutCents == 0)
        #expect(unentered.tipOutCents != explicitZero.tipOutCents)

        // Identical as digests: the change-detector matches the engine.
        let a = try InputManifest(
            shifts: [unentered], paychecks: [], schedule: nil,
            rates: [], calendars: [], asOf: day
        )
        let b = try InputManifest(
            shifts: [explicitZero], paychecks: [], schedule: nil,
            rates: [], calendars: [], asOf: day
        )
        #expect(a.digest == b.digest)
        #expect(a.shiftsDigest == b.shiftsDigest)

        // A real tip-out still moves the digest, so the collapse is scoped to
        // the nil/0 pair and has not blunted the detector.
        let real = try InputManifest(
            shifts: [shift(1_000)], paychecks: [], schedule: nil,
            rates: [], calendars: [], asOf: day
        )
        #expect(real.digest != a.digest)
    }

    @Test("Canonical text matches the documented contract byte for byte")
    func canonicalTextMatches() throws {
        #expect(try Self.encodedText() == Self.canonicalText)
    }

    @Test("Digest of the canonical manifest is the pinned 64-char hex")
    func pinnedDigest() throws {
        let m = try Self.manifest()
        #expect(m.digest.count == 64)
        #expect(m.digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(m.digest == Self.pinnedDigest)
        #expect(InputManifest.sha256Hex(Self.canonicalText) == Self.pinnedDigest)
    }

    @Test("Sub-digests are SHA-256 of the literal section texts")
    func subDigestsPinnedToSectionText() throws {
        let m = try Self.manifest()
        #expect(m.shiftsDigest == InputManifest.sha256Hex(Self.shiftsSection))
        #expect(m.paychecksDigest == InputManifest.sha256Hex(Self.paychecksSection))
        #expect(m.scheduleDigest == InputManifest.sha256Hex(Self.scheduleSection))
        #expect(m.policiesDigest == InputManifest.sha256Hex(Self.policiesSection))
    }

    @Test("Shift lines sort by id, not by workDay")
    func shiftsSortByID() throws {
        // shiftC has the earliest workDay (09-21) but the largest id; it must be last.
        let lines = try Self.encodedText().split(separator: "\n").filter { $0.hasPrefix("S|") }
        // #require, not #expect: #expect records and continues, so a wrong count
        // would trap the whole runner on the next subscript and hide every other
        // test's result (a CRLF join, say, emits zero "S|" lines).
        try #require(lines.count == 3)
        #expect(lines[0].hasPrefix("S|11111111"))
        #expect(lines[1].hasPrefix("S|22222222"))
        #expect(lines[2].hasPrefix("S|99999999"))
        #expect(lines[2].contains("|2026-09-21|"))
        #expect(lines[0].contains("|2026-09-28|"))
    }

    @Test("recordedAt truncates toward zero to whole seconds")
    func recordedAtTruncates() throws {
        #expect(Self.shifts[0].recordedAt == Date(timeIntervalSince1970: 1_790_000_000.9))
        let text = try InputManifest.canonicalText(shifts: [Self.shifts[0]])
        // #require, not `!`: a force-unwrap here would trap the whole runner
        // and hide every other test's result if the encoding ever stopped
        // producing an "S|" line on its own (a CRLF join, say).
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("S|") },
                                "no S| line in \(text.debugDescription)")
        #expect(line.contains("|dinner|1790000000|"))
        #expect(!line.contains("1790000001"))
    }

    @Test("Rates order by effectiveFrom before id; calendars tiebreak on id; rates precede calendars")
    func policyOrdering() throws {
        let lines = try Self.encodedText().split(separator: "\n").map(String.init)
        let rateIdx = lines.indices.filter { lines[$0].hasPrefix("R|") }
        let calIdx = lines.indices.filter { lines[$0].hasPrefix("C|") }
        // #require before any indexing, for the same reason as `shiftsSortByID`.
        try #require(rateIdx.count == 2)
        try #require(calIdx.count == 2)
        // Every rate line comes before every calendar line.
        #expect(try #require(rateIdx.max()) < #require(calIdx.min()))
        // rate1 (later id, earlier effectiveFrom) first.
        #expect(lines[rateIdx[0]].hasPrefix("R|44444444"))
        #expect(lines[rateIdx[1]].hasPrefix("R|0AAAAAAA"))
        // Equal effectiveFrom: smaller id first, regardless of insertion order.
        #expect(lines[calIdx[0]].hasPrefix("C|55555555-5555-4555-8555-555555555500"))
        #expect(lines[calIdx[1]].hasPrefix("C|55555555-5555-4555-8555-555555555555"))
        // And the fixture really was inserted the other way round.
        #expect(Self.rates[0].id == Self.rateLate)
        #expect(Self.calendars[1].id == Self.calendarTie)
    }

    /// `policiesDigest` hashes `rateLines + calendarLines` as one section, so
    /// the rates-before-calendars rule lives in that concatenation rather than
    /// in the full text (where two count headers separate the two kinds
    /// structurally). Without this test the rule is guarded only by the pinned
    /// `policiesSection` hash, which names nothing when it moves.
    @Test("policiesDigest's section writes every rate line before every calendar line")
    func policiesSectionPutsRatesBeforeCalendars() throws {
        let m = try Self.manifest()
        let rateLines = InputManifest.Canonical.rateLines(Self.rates)
        let calendarLines = InputManifest.Canonical.calendarLines(Self.calendars)
        #expect(rateLines.count == 2)
        #expect(calendarLines.count == 2)

        let ratesFirst = InputManifest.Canonical.sectionText(rateLines + calendarLines)
        let calendarsFirst = InputManifest.Canonical.sectionText(calendarLines + rateLines)
        // The digest the encoder actually produced is over the rates-first
        // text, and demonstrably not over the other arrangement.
        #expect(m.policiesDigest == InputManifest.sha256Hex(ratesFirst))
        #expect(m.policiesDigest != InputManifest.sha256Hex(calendarsFirst))

        // And in that text every R| index really is below every C| index.
        let lines = ratesFirst.split(separator: "\n").map(String.init)
        let rateIdx = lines.indices.filter { lines[$0].hasPrefix("R|") }
        let calIdx = lines.indices.filter { lines[$0].hasPrefix("C|") }
        #expect(rateIdx.count == 2)
        #expect(calIdx.count == 2)
        #expect(try #require(rateIdx.max()) < #require(calIdx.min()))
    }

    @Test("Sub-digests are 64-char lowercase hex and distinct from each other")
    func subDigestShape() throws {
        let m = try Self.manifest()
        for d in [m.shiftsDigest, m.paychecksDigest, m.scheduleDigest, m.policiesDigest] {
            #expect(d.count == 64)
            #expect(d.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        #expect(Set([m.shiftsDigest, m.paychecksDigest, m.scheduleDigest, m.policiesDigest, m.digest]).count == 5)
        #expect(m.shiftCount == 3)
        #expect(m.paycheckCount == 1)
        #expect(m.ratePolicyCount == 2)
        #expect(m.calendarPolicyCount == 2)
        #expect(m.engineVersion == 1)
        #expect(m.asOf == Self.asOf)
    }

    @Test("Digest is identical for shuffled input")
    func orderIndependent() throws {
        let base = try Self.manifest()
        var generator = SystemRandomNumberGenerator()
        // Many shifts and policies so a shuffle almost surely reorders.
        let manyShifts = (0..<40).map { i in
            ShiftInput(id: UUID(), workDay: CivilDay(year: 2026, month: 9, day: 1).adding(days: i % 28),
                       voluntaryCashCents: i * 100, minutesWorked: i % 3 == 0 ? nil : 300 + i)
        }
        let manyRates = (0..<6).map { i in
            PayRatePolicy(id: UUID(), effectiveFrom: CivilDay(year: 2025, month: 1, day: 1).adding(days: 30 * i),
                          hourlyRateCents: 283 + i, provenance: i % 2 == 0 ? .confirmed : .assumedFromLegacySetting)
        }
        let manyCalendars = (0..<3).map { i in
            PayrollCalendarPolicy(id: UUID(), effectiveFrom: CivilDay(year: 2025, month: 1, day: 6).adding(days: 7 * 10 * i),
                                  workweekStartWeekday: 1 + i, payrollTimeZone: TimeZone(identifier: "America/New_York")!)
        }
        let manyPaychecks = (0..<8).map { i in
            PaycheckInput(id: UUID(), periodStart: CivilDay(year: 2026, month: 1, day: 5).adding(days: 14 * i),
                          periodEnd: CivilDay(year: 2026, month: 1, day: 18).adding(days: 14 * i), paidTipsCents: 1000 * i)
        }
        let ordered = try Self.manifest(shifts: manyShifts, paychecks: manyPaychecks, rates: manyRates, calendars: manyCalendars)
        for _ in 0..<5 {
            let shuffled = try Self.manifest(
                shifts: manyShifts.shuffled(using: &generator),
                paychecks: manyPaychecks.shuffled(using: &generator),
                rates: manyRates.shuffled(using: &generator),
                calendars: manyCalendars.shuffled(using: &generator)
            )
            #expect(shuffled == ordered)
        }
        #expect(try Self.manifest(shifts: Self.shifts.reversed(), rates: Self.rates.reversed(), calendars: Self.calendars.reversed()) == base)
    }

    // MARK: Duplicate sort keys (the sort must be a TOTAL order)

    /// `sorted` is not documented as stable in Swift, so a sort key that is
    /// not a total order makes the digest depend on the order the store
    /// happened to return rows in. A caller unioning two overlapping fetches
    /// (`shiftsInRange + shiftsForPaycheck`) produces exactly this input, and
    /// nothing rejects it, so the encoding has to be deterministic anyway.
    /// The whole encoded line is the final tiebreak, which makes it so.
    @Test("20 shifts sharing one id digest the same forwards and backwards")
    func duplicateShiftIDsAreOrderIndependent() throws {
        let shared = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let dupes = (0..<20).map { i in
            ShiftInput(id: shared, workDay: CivilDay(year: 2026, month: 9, day: 1).adding(days: i),
                       voluntaryCashCents: i * 100, minutesWorked: 300 + i)
        }
        let forward = try InputManifest(shifts: dupes, asOf: nil)
        let backward = try InputManifest(shifts: dupes.reversed(), asOf: nil)
        #expect(forward.shiftsDigest == backward.shiftsDigest)
        #expect(forward.digest == backward.digest)
        #expect(forward == backward)
        // Every line is kept (no dedupe) and the canonical order is sorted.
        let lines = try InputManifest.canonicalText(shifts: dupes.reversed(), asOf: nil)
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("S|") }
        #expect(lines.count == 20)
        #expect(lines == lines.sorted())
        // And a shuffle of the duplicates is the same digest too.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            #expect(try InputManifest(shifts: dupes.shuffled(using: &generator), asOf: nil) == forward)
        }
    }

    @Test("Paychecks sharing one id digest the same forwards and backwards")
    func duplicatePaycheckIDsAreOrderIndependent() throws {
        let shared = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let dupes = (0..<12).map { i in
            PaycheckInput(id: shared, periodStart: CivilDay(year: 2026, month: 1, day: 5).adding(days: 14 * i),
                          periodEnd: CivilDay(year: 2026, month: 1, day: 18).adding(days: 14 * i), paidTipsCents: 1000 * i)
        }
        let forward = try InputManifest(shifts: [], paychecks: dupes, asOf: nil)
        #expect(try InputManifest(shifts: [], paychecks: dupes.reversed(), asOf: nil) == forward)
        #expect(forward.paycheckCount == 12)
    }

    @Test("Rates and calendars sharing an (effectiveFrom, id) pair digest the same forwards and backwards")
    func duplicatePolicyKeysAreOrderIndependent() throws {
        let day = CivilDay(year: 2026, month: 3, day: 2)
        let sharedRate = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let rates = (0..<8).map { i in
            PayRatePolicy(id: sharedRate, effectiveFrom: day, hourlyRateCents: 283 + i,
                          provenance: i % 2 == 0 ? .confirmed : .assumedFromLegacySetting)
        }
        let sharedCalendar = UUID(uuidString: "6A6A6A6A-6A6A-46A6-86A6-6A6A6A6A6A6A")!
        let calendars = (1...7).map { weekday in
            PayrollCalendarPolicy(id: sharedCalendar, effectiveFrom: day, workweekStartWeekday: weekday,
                                  payrollTimeZone: TimeZone(identifier: "America/New_York")!)
        }
        let forward = try InputManifest(shifts: [], rates: rates, calendars: calendars, asOf: nil)
        let backward = try InputManifest(shifts: [], rates: rates.reversed(), calendars: calendars.reversed(), asOf: nil)
        #expect(forward.policiesDigest == backward.policiesDigest)
        #expect(forward.digest == backward.digest)
        #expect(forward.ratePolicyCount == 8 && forward.calendarPolicyCount == 7)
    }

    // MARK: Mutation matrix

    /// One mutation per input family. Each must change the full digest and
    /// exactly its own sub-digest, and nothing else.
    @Test("Mutation matrix: reorder is a no-op, one cent changes only its own section", arguments: [
        "shifts", "paychecks", "schedule", "rates", "calendars",
    ])
    func mutationMatrix(family: String) throws {
        let base = try Self.manifest()

        var shifts = Self.shifts
        var paychecks = Self.paychecks
        var schedule = Self.schedule
        var rates = Self.rates
        var calendars = Self.calendars

        switch family {
        case "shifts": shifts[1].voluntaryCreditCents += 1
        case "paychecks": paychecks[0].paidTipsCents += 1
        case "schedule": schedule.payDelayDays += 1
        case "rates": rates[1].hourlyRateCents += 1
        case "calendars": calendars[0].overtimeThresholdMinutes += 1
        default: Issue.record("unknown family \(family)")
        }

        // Reordering the mutated inputs must not matter either.
        let mutated = try Self.manifest(shifts: shifts, paychecks: paychecks, schedule: schedule, rates: rates, calendars: calendars)
        let mutatedShuffled = try Self.manifest(shifts: shifts.reversed(), paychecks: paychecks, schedule: schedule,
                                            rates: rates.reversed(), calendars: calendars.reversed())
        #expect(mutated == mutatedShuffled)

        #expect(mutated.digest != base.digest)
        #expect((mutated.shiftsDigest != base.shiftsDigest) == (family == "shifts"))
        #expect((mutated.paychecksDigest != base.paychecksDigest) == (family == "paychecks"))
        #expect((mutated.scheduleDigest != base.scheduleDigest) == (family == "schedule"))
        #expect((mutated.policiesDigest != base.policiesDigest) == (family == "rates" || family == "calendars"))
    }

    @Test("Changing one cent on one shift changes shiftsDigest and digest only")
    func oneCentChanges() throws {
        let base = try Self.manifest()
        var shifts = Self.shifts
        shifts[1].voluntaryCreditCents += 1
        let changed = try Self.manifest(shifts: shifts)
        #expect(changed.digest != base.digest)
        #expect(changed.shiftsDigest != base.shiftsDigest)
        #expect(changed.paychecksDigest == base.paychecksDigest)
        #expect(changed.scheduleDigest == base.scheduleDigest)
        #expect(changed.policiesDigest == base.policiesDigest)
    }

    @Test("Editing a paycheck changes paychecksDigest only")
    func paycheckIsolation() throws {
        let base = try Self.manifest()
        var paychecks = Self.paychecks
        paychecks[0].paidTipsCents = 10050
        let changed = try Self.manifest(paychecks: paychecks)
        #expect(changed.digest != base.digest)
        #expect(changed.paychecksDigest != base.paychecksDigest)
        #expect(changed.shiftsDigest == base.shiftsDigest)
        #expect(changed.scheduleDigest == base.scheduleDigest)
        #expect(changed.policiesDigest == base.policiesDigest)
    }

    @Test("Changing the schedule changes scheduleDigest only")
    func scheduleIsolation() throws {
        let base = try Self.manifest()
        var schedule = Self.schedule
        schedule.firstWeekday = 1
        let changed = try Self.manifest(schedule: schedule)
        #expect(changed.digest != base.digest)
        #expect(changed.scheduleDigest != base.scheduleDigest)
        #expect(changed.shiftsDigest == base.shiftsDigest)
        #expect(changed.paychecksDigest == base.paychecksDigest)
        #expect(changed.policiesDigest == base.policiesDigest)
        let noSchedule = try Self.manifest(schedule: nil)
        #expect(noSchedule.scheduleDigest != base.scheduleDigest)
    }

    @Test("Changing a policy changes policiesDigest only")
    func policyIsolation() throws {
        let base = try Self.manifest()
        var rates = Self.rates
        rates[1].provenance = .assumedFromLegacySetting
        let changedRate = try Self.manifest(rates: rates)
        #expect(changedRate.policiesDigest != base.policiesDigest)
        #expect(changedRate.shiftsDigest == base.shiftsDigest)
        #expect(changedRate.paychecksDigest == base.paychecksDigest)
        #expect(changedRate.scheduleDigest == base.scheduleDigest)

        var calendars = Self.calendars
        calendars[0].payrollTimeZone = TimeZone(identifier: "Pacific/Honolulu")!
        let changedCalendar = try Self.manifest(calendars: calendars)
        #expect(changedCalendar.policiesDigest != base.policiesDigest)
        #expect(changedCalendar.policiesDigest != changedRate.policiesDigest)
        #expect(changedCalendar.shiftsDigest == base.shiftsDigest)
    }

    @Test("asOf and engineVersion change only the full digest")
    func asOfAndEngineVersion() throws {
        let base = try Self.manifest()
        let later = try Self.manifest(asOf: Self.asOf.adding(days: 1))
        #expect(later.digest != base.digest)
        #expect(later.shiftsDigest == base.shiftsDigest)
        #expect(later.paychecksDigest == base.paychecksDigest)
        #expect(later.scheduleDigest == base.scheduleDigest)
        #expect(later.policiesDigest == base.policiesDigest)

        let bumped = try InputManifest(shifts: Self.shifts, paychecks: Self.paychecks, schedule: Self.schedule,
                                   rates: Self.rates, calendars: Self.calendars, asOf: Self.asOf, engineVersion: 2)
        #expect(bumped.digest != base.digest)
        #expect(bumped.shiftsDigest == base.shiftsDigest)
    }

    @Test("Empty inputs produce a stable, well-formed manifest")
    func emptyManifest() throws {
        let m = try InputManifest(shifts: [], asOf: nil)
        #expect(m.shiftCount == 0)
        #expect(m.digest.count == 64)
        #expect(m.shiftsDigest == InputManifest.sha256Hex("paydaycore-manifest-v1\n"))
        #expect(m.scheduleDigest == InputManifest.sha256Hex("paydaycore-manifest-v1\nschedule|-"))
        #expect(try InputManifest(shifts: [], asOf: nil) == m)
    }

    @Test("Manifest round-trips through Codable")
    func codable() throws {
        let m = try Self.manifest()
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(InputManifest.self, from: data) == m)
    }

    // MARK: Reserved characters (review P2 b)

    @Test("validate rejects a frequency containing '|' or a newline")
    func validateRejectsReservedFrequency() {
        for bad in ["week|ly", "weekly\n", "|", "bi\nweekly|"] {
            let schedule = PayScheduleInput(frequency: bad, anchorPeriodEnd: Self.asOf, payDelayDays: 0)
            #expect(throws: InputManifest.ValidationError.self) {
                try InputManifest.validate(schedule: schedule, calendars: Self.calendars)
            }
            do {
                try InputManifest.validate(schedule: schedule, calendars: [])
                Issue.record("expected \(bad.debugDescription) to be rejected")
            } catch let error as InputManifest.ValidationError {
                #expect(error == .reservedCharacter(field: "schedule.frequency", value: bad))
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    /// The refusal has to be the constructor's, not the caller's: these inputs
    /// arrive from decoded JSON (fixtures today, synced payloads in PR 6), so
    /// a bad payload must be a reportable error and not a release-build trap
    /// in the money path.
    @Test("init throws rather than trapping on a reserved character")
    func initThrowsOnReservedCharacter() throws {
        let schedule = PayScheduleInput(frequency: "bi|weekly", anchorPeriodEnd: Self.asOf, payDelayDays: 0)
        #expect(throws: InputManifest.ValidationError.reservedCharacter(field: "schedule.frequency", value: "bi|weekly")) {
            _ = try InputManifest(shifts: Self.shifts, schedule: schedule, asOf: Self.asOf)
        }
        #expect(throws: InputManifest.ValidationError.self) {
            _ = try InputManifest.canonicalText(shifts: Self.shifts, schedule: schedule, asOf: Self.asOf)
        }
        let calendars = [PayrollCalendarPolicy(id: UUID(), effectiveFrom: Self.asOf, workweekStartWeekday: 2,
                                               payrollTimeZone: TimeZone(identifier: "America/New_York")!)]
        // Clean inputs still construct.
        _ = try InputManifest(shifts: Self.shifts, schedule: Self.schedule, calendars: calendars, asOf: Self.asOf)
    }

    @Test("validate accepts the canonical fixture, a nil schedule, and every known time zone identifier")
    func validateAcceptsCleanInput() throws {
        try InputManifest.validate(schedule: Self.schedule, calendars: Self.calendars)
        try InputManifest.validate(schedule: nil, calendars: [])
        // TimeZone identifiers are the only other free-text field; none may ever carry a delimiter.
        let zones = TimeZone.knownTimeZoneIdentifiers
        #expect(!zones.isEmpty)
        #expect(zones.allSatisfy { !$0.contains("|") && !$0.contains("\n") })
        let calendars = zones.prefix(50).enumerated().map { i, id in
            PayrollCalendarPolicy(id: UUID(), effectiveFrom: Self.asOf.adding(days: -7 * i), workweekStartWeekday: 2,
                                  payrollTimeZone: TimeZone(identifier: id)!)
        }
        try InputManifest.validate(schedule: Self.schedule, calendars: calendars)
    }

    // MARK: Unrepresentable recordedAt (verification P1)

    /// `ShiftInput.recordedAt` is a `Date`, and `Date` decodes from JSON as a
    /// plain `Double`, so `{"recordedAt": 1e300}` is a shift that DECODES
    /// cleanly and only explodes later. The encoder used to do
    /// `Int(date.timeIntervalSince1970)`, which aborts the process on a value
    /// that big. It must be a reportable error instead, for the same reason
    /// the reserved-character check is: the payload comes from outside
    /// (fixtures pass nil today; PR 6 sync and the app adapter feed real
    /// dates in) and a bad one may not crash the money path.
    @Test("A decoded out-of-range recordedAt throws rather than trapping",
          arguments: ["1e300", "-1e300", "9.3e18"])
    func outOfRangeRecordedAtThrows(raw: String) throws {
        let json = """
        {"id":"11111111-1111-4111-8111-111111111111","workDay":"2026-09-28","recordedAt":\(raw),\
        "voluntaryCashCents":0,"voluntaryCreditCents":0,"gratuityFeesCents":0}
        """
        let shift = try JSONDecoder().decode(ShiftInput.self, from: Data(json.utf8))
        #expect(shift.recordedAt != nil, "the point of the test is that this payload decodes")

        #expect(throws: InputManifest.ValidationError.self) {
            try InputManifest.validate(shifts: [shift], schedule: nil, calendars: [])
        }
        #expect(throws: InputManifest.ValidationError.self) {
            _ = try InputManifest(shifts: [shift], asOf: Self.asOf)
        }
        #expect(throws: InputManifest.ValidationError.self) {
            _ = try InputManifest.canonicalText(shifts: [shift], asOf: Self.asOf)
        }
        do {
            try InputManifest.validate(shifts: [shift], schedule: nil, calendars: [])
            Issue.record("expected recordedAt \(raw) to be rejected")
        } catch let error as InputManifest.ValidationError {
            #expect(error == .unrepresentableDate(shiftID: Self.shiftA,
                                                  value: shift.recordedAt!.timeIntervalSince1970))
        }
    }

    @Test("A non-finite recordedAt is rejected too")
    func nonFiniteRecordedAtThrows() throws {
        for seconds in [Double.nan, .infinity, -.infinity] {
            let shift = ShiftInput(id: Self.shiftA, workDay: CivilDay(year: 2026, month: 9, day: 28),
                                   recordedAt: Date(timeIntervalSince1970: seconds))
            #expect(throws: InputManifest.ValidationError.self) {
                _ = try InputManifest(shifts: [shift], asOf: Self.asOf)
            }
        }
    }

    /// `validate` is the gate, but the encoder must be total on its own: a
    /// caller that skips validation (or a future section that forgets to run
    /// it) may get a useless line, never a dead process.
    @Test("The encoder itself never traps on an unrepresentable date")
    func encoderIsTotal() throws {
        #expect(InputManifest.Canonical.wholeSeconds(Date(timeIntervalSince1970: 1_790_000_000.9)) == 1_790_000_000)
        #expect(InputManifest.Canonical.wholeSeconds(Date(timeIntervalSince1970: -1.9)) == -1)
        #expect(InputManifest.Canonical.wholeSeconds(Date(timeIntervalSince1970: 1e300)) == nil)
        #expect(InputManifest.Canonical.wholeSeconds(Date(timeIntervalSince1970: .nan)) == nil)
        #expect(InputManifest.Canonical.wholeSeconds(Date(timeIntervalSince1970: .infinity)) == nil)

        let shift = ShiftInput(id: Self.shiftA, workDay: CivilDay(year: 2026, month: 9, day: 28),
                               recordedAt: Date(timeIntervalSince1970: 1e300))
        let lines = InputManifest.Canonical.shiftLines([shift])
        // #require before indexing, for the same reason as `shiftsSortByID`.
        try #require(lines.count == 1)
        // Field 5 is recordedAt; an unrepresentable date degrades to the nil marker.
        let fields = lines[0].split(separator: "|", omittingEmptySubsequences: false)
        try #require(fields.count >= 5)
        #expect(fields[4] == "-")
    }

    /// Every representable date encodes exactly as before, so adding the
    /// bound is not a `formatVersion` bump. The pinned canonical text in
    /// `canonicalTextIsPinned` covers the fixture; this covers the edges.
    @Test("Representable dates encode unchanged (no format-version bump)")
    func representableDatesUnchanged() {
        for seconds in [0.0, 1.0, -1.0, 1_790_000_000.9, -1_790_000_000.9, 1e15, -1e15] {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(InputManifest.Canonical.wholeSeconds(date) == Int(seconds.rounded(.towardZero)))
        }
    }
}
