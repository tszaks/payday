import Testing
import Foundation
import SwiftData
@testable import Payday

// MARK: - Test doubles

private let payroll = TimeZone(identifier: "America/New_York")!

private func day(_ year: Int, _ month: Int, _ d: Int) -> CivilDay {
    CivilDay(year: year, month: month, day: d)
}

private func instant(_ year: Int, _ month: Int, _ d: Int, hour: Int = 17) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = payroll
    return calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour))!
}

private func shiftID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private let calendarPolicy = PayrollCalendarPolicy(
    id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!,
    effectiveFrom: day(2025, 12, 29),
    workweekStartWeekday: 2,
    payrollTimeZone: payroll
)

private let ratePolicy = PayRatePolicy(
    id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!,
    effectiveFrom: day(2025, 12, 29),
    hourlyRateCents: 283,
    provenance: .confirmed
)

/// W1's two shifts: 255 + 330 minutes in one Monday-start week at 283c,
/// which the ledger values 1203 + 1556 = 2759.
private func w1Inputs(asOf: CivilDay = day(2026, 10, 2)) -> EarningsInputs {
    EarningsInputs(
        shifts: [
            ShiftInput(id: shiftID(1), workDay: day(2026, 9, 28), period: .lunch,
                       voluntaryCreditCents: 5_000, minutesWorked: 255),
            ShiftInput(id: shiftID(2), workDay: day(2026, 9, 28), period: .dinner,
                       voluntaryCreditCents: 6_000, minutesWorked: 330),
        ],
        schedule: PayScheduleInput(frequency: "biweekly", anchorPeriodEnd: day(2026, 10, 4),
                                   payDelayDays: 5, firstWeekday: 2),
        rates: [ratePolicy],
        calendars: [calendarPolicy],
        asOf: asOf
    )
}

/// A source the test drives: swap the inputs, make the next fetch throw,
/// count the fetches.
@MainActor
private final class FakeSource: EarningsInputSource {
    var fetch: EarningsFetch
    var nextFetchThrows = false
    private(set) var fetchCount = 0

    struct Boom: Error, CustomStringConvertible {
        var description: String { "the store is on fire" }
    }

    init(inputs: EarningsInputs = w1Inputs(), legacyTipEntryCount: Int = 0) {
        fetch = EarningsFetch(inputs: inputs, legacyTipEntryCount: legacyTipEntryCount)
    }

    func fetchInputs() throws -> EarningsFetch {
        fetchCount += 1
        if nextFetchThrows {
            nextFetchThrows = false
            throw Boom()
        }
        return fetch
    }
}

/// Polls on the main actor until `condition` holds or the deadline passes.
/// Preferred over a fixed sleep so a fast machine does not wait and a slow
/// one does not flake.
@MainActor
private func until(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for: \(description)")
}

// MARK: - Pipeline

@Suite("EarningsStore pipeline")
@MainActor
struct EarningsStorePipelineTests {
    @Test("the first rebuild publishes a snapshot, and loading is not zero")
    func firstRebuildPublishes() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)

        #expect(store.state == .loading)
        #expect(store.snapshot == nil)

        await store.rebuildNow(reason: .initial)

        guard case .ready(let snapshot, let refreshing) = store.state else {
            Issue.record("expected .ready, got \(store.state)")
            return
        }
        #expect(refreshing == false)
        #expect(snapshot.stamp.generation == 1)
        #expect(snapshot.range(DayRange(start: day(2026, 9, 28), end: day(2026, 10, 4)))
            .knownComponents.earnedIncomeCents == 11_000 + 2_759, "W1's tips plus W1's wages")
        #expect(store.publishedCount == 1)
        #expect(store.skippedCount == 0)
    }

    /// The guard that makes the whole design safe: an older computation
    /// must never overwrite a newer one.
    ///
    /// The slow builder blocks on generation 1 only. Rebuild twice: the
    /// second publishes immediately, the first returns half a second later
    /// and has to be thrown away. Without `guard g == generation` the store
    /// would end up showing generation 1's snapshot.
    @Test("a stale generation is dropped")
    func aStaleGenerationIsDropped() async {
        let source = FakeSource()
        let store = EarningsStore(
            source: source,
            builder: { inputs, generation in
                if generation == 1 {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                return try EarningsSnapshot.build(inputs, generation: generation)
            },
            debounceNanoseconds: 0,
            observesTriggers: false
        )

        store.requestRebuild(reason: .manual)
        // Let generation 1 reach its detached build before asking again, so
        // the two really are in flight together rather than one replacing a
        // task that never started.
        await until("the slow build to be in flight") { source.fetchCount == 1 }
        store.requestRebuild(reason: .modelContextDidSave)

        await until("generation 2 to publish") { store.publishedCount == 1 }
        #expect(store.snapshot?.stamp.generation == 2)

        // Now outlive generation 1's builder and prove it changed nothing.
        try? await Task.sleep(for: .seconds(1))
        #expect(store.snapshot?.stamp.generation == 2, "generation 1 must not overwrite generation 2")
        #expect(store.publishedCount == 1, "the stale result is dropped, not published")
    }

    @Test("an identical digest skips publishing")
    func identicalDigestSkipsPublishing() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)

        await store.rebuildNow()
        let first = store.snapshot
        await store.rebuildNow()

        #expect(store.publishedCount == 1)
        #expect(store.skippedCount == 1)
        #expect(store.snapshot?.stamp == first?.stamp, "the same snapshot instance stays published")
        #expect(store.snapshot?.stamp.generation == 1)
        #expect(store.isRefreshing == false)
        #expect(source.fetchCount == 2, "the skip happens after the fetch, not instead of it")
    }

    @Test("a changed input publishes a new snapshot")
    func changedInputPublishes() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)
        await store.rebuildNow()
        let before = store.snapshot!

        var changed = w1Inputs()
        changed.shifts[1].minutesWorked = 390
        source.fetch = EarningsFetch(inputs: changed, legacyTipEntryCount: 0)
        await store.rebuildNow()

        #expect(store.publishedCount == 2)
        #expect(store.skippedCount == 0)
        #expect(store.snapshot?.stamp.digest != before.stamp.digest)
        #expect(store.snapshot?.stamp.manifest.shiftsDigest != before.stamp.manifest.shiftsDigest)
        #expect(store.snapshot?.stamp.manifest.policiesDigest == before.stamp.manifest.policiesDigest)
    }

    /// A new civil day changes nothing about the shifts and everything
    /// about a period-to-date total, so it must NOT be skipped.
    @Test("a new asOf is not an unchanged digest")
    func newAsOfRebuilds() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)
        await store.rebuildNow()

        source.fetch = EarningsFetch(inputs: w1Inputs(asOf: day(2026, 10, 3)), legacyTipEntryCount: 0)
        await store.rebuildNow()

        #expect(store.skippedCount == 0)
        #expect(store.publishedCount == 2)
        #expect(store.snapshot?.stamp.asOf == day(2026, 10, 3))
    }

    @Test("a fetch failure publishes .unavailable and keeps the last snapshot")
    func fetchFailureKeepsTheLastSnapshot() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)
        await store.rebuildNow()
        let good = store.snapshot

        source.nextFetchThrows = true
        await store.rebuildNow()

        guard case .unavailable(let reason, let last) = store.state else {
            Issue.record("expected .unavailable, got \(store.state)")
            return
        }
        #expect(reason == .fetchFailed(detail: "\(FakeSource.Boom())"))
        #expect(reason.message == "Payday couldn't read your shifts right now.")
        #expect(last == good, "the numbers already on screen stay on screen")
        #expect(store.snapshot == good)

        // And it recovers on the next successful fetch.
        await store.rebuildNow()
        #expect(store.snapshot?.stamp.generation == 3)
        if case .ready = store.state {} else {
            Issue.record("expected .ready after recovery, got \(store.state)")
        }
    }

    /// The failure path must not lose the identical-digest comparison: a
    /// recovery whose inputs are unchanged still has to republish, because
    /// the state is `.unavailable` and nothing is on screen.
    @Test("recovering from .unavailable republishes even with an unchanged digest")
    func recoveryRepublishesUnchangedInputs() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)
        source.nextFetchThrows = true
        await store.rebuildNow()
        #expect(store.publishedCount == 0)

        await store.rebuildNow()
        #expect(store.publishedCount == 1)
        #expect(store.skippedCount == 0)
    }

    @Test("inputs that cannot be fingerprinted are refused, not published")
    func invalidInputsAreRefused() async {
        // A `|` in the schedule frequency would make the canonical manifest
        // text ambiguous, so `InputManifest` refuses it.
        var poisoned = w1Inputs()
        poisoned.schedule = PayScheduleInput(
            frequency: "bi|weekly", anchorPeriodEnd: day(2026, 10, 4), payDelayDays: 5
        )
        let source = FakeSource(inputs: poisoned)
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)

        await store.rebuildNow()

        guard case .unavailable(let reason, let last) = store.state else {
            Issue.record("expected .unavailable, got \(store.state)")
            return
        }
        if case .inputsInvalid = reason {} else {
            Issue.record("expected .inputsInvalid, got \(reason)")
        }
        #expect(last == nil)
        #expect(store.publishedCount == 0)
    }

    @Test("isRefreshing is true while a rebuild runs and false once it publishes")
    func isRefreshingTracksTheRebuild() async {
        let source = FakeSource()
        let store = EarningsStore(
            source: source,
            builder: { inputs, generation in
                if generation == 2 { Thread.sleep(forTimeInterval: 0.3) }
                return try EarningsSnapshot.build(inputs, generation: generation)
            },
            debounceNanoseconds: 0,
            observesTriggers: false
        )
        await store.rebuildNow()
        #expect(store.isRefreshing == false)

        var changed = w1Inputs()
        changed.shifts[0].minutesWorked = 300
        source.fetch = EarningsFetch(inputs: changed, legacyTipEntryCount: 0)
        store.requestRebuild()

        await until("the refresh to start") { store.isRefreshing }
        #expect(store.snapshot?.stamp.generation == 1, "the old snapshot stays visible meanwhile")
        await until("the refresh to finish") { store.publishedCount == 2 }
        #expect(store.isRefreshing == false)
    }
}

// MARK: - Triggers

@Suite("EarningsStore triggers")
@MainActor
struct EarningsStoreTriggerTests {
    /// A settings edit (rate, schedule, calendar policy) moves numbers
    /// without touching a single shift row, so `ModelContext.didSave` never
    /// fires for it. This is the trigger that covers that.
    @Test("the settings clock triggers a rebuild")
    func settingsClockTriggersARebuild() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0)
        await store.rebuildNow()
        #expect(store.publishedCount == 1)

        var changed = w1Inputs()
        changed.shifts[0].minutesWorked = 300
        source.fetch = EarningsFetch(inputs: changed, legacyTipEntryCount: 0)

        // A scratch suite: the notification is what the store listens to,
        // and writing the real App Group's clock from a test would look like
        // a device edit to the sync layer.
        let suite = UserDefaults(suiteName: "com.szakacsmedia.payday.tests.earningsStore")!
        PaydaySettingsSyncClock.touch(defaults: suite)

        await until("the settings clock to drive a rebuild") { store.publishedCount == 2 }
        #expect(store.snapshot?.stamp.generation == 2)
        suite.removePersistentDomain(forName: "com.szakacsmedia.payday.tests.earningsStore")
    }

    /// A policy arriving from the server moves every wage in the app and
    /// deliberately does NOT touch `PaydaySettingsSyncClock` (touching it
    /// would make this device look like it had edited the value it just
    /// received). `PolicyStore.didChange` is the only signal, which is why
    /// this test drives `replaceFromSupabase` rather than a user edit.
    @Test("a downloaded policy triggers a rebuild through PolicyStore.didChange")
    func policyStoreTriggersARebuild() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0)
        await store.rebuildNow()
        #expect(store.snapshot?.day(day(2026, 9, 28)).knownComponents.wagesCents == 2_759)

        let raise = PayRatePolicy(
            id: ratePolicy.id, effectiveFrom: ratePolicy.effectiveFrom,
            hourlyRateCents: 300, provenance: .confirmed
        )
        var changed = w1Inputs()
        changed.rates = [raise]
        source.fetch = EarningsFetch(inputs: changed, legacyTipEntryCount: 0)

        let suiteName = "com.szakacsmedia.payday.tests.earningsPolicies"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let policies = PolicyStore(defaults: suite)
        let before = PaydaySettingsSyncClock.modifiedAt(in: suite)
        policies.replaceFromSupabase(CompensationPolicies(rates: [raise], calendars: [calendarPolicy]))

        await until("the policy write to drive a rebuild") { store.publishedCount == 2 }
        // 585 minutes at $3.00/h is exactly $29.25, so the new rate is
        // visible as a whole number rather than a rounding artifact.
        #expect(store.snapshot?.day(day(2026, 9, 28)).knownComponents.wagesCents == 2_925)
        #expect(PaydaySettingsSyncClock.modifiedAt(in: suite) == before,
                "a download must not look like a local edit")
        suite.removePersistentDomain(forName: suiteName)
    }

    /// One save fires `ModelContext.didSave`, the settings clock and the
    /// policy store within microseconds. The debounce is what keeps that
    /// from valuing every shift three times.
    @Test("a burst of triggers coalesces into one rebuild")
    func burstCoalesces() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 20_000_000)

        store.requestRebuild(reason: .modelContextDidSave)
        store.requestRebuild(reason: .settingsClockDidChange)
        store.requestRebuild(reason: .policiesDidChange)

        await until("the coalesced rebuild") { store.publishedCount == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.publishedCount == 1)
        #expect(source.fetchCount == 1, "one fetch for the whole burst")
    }
}

// MARK: - Preview, buildOnce, wiped cache

@Suite("EarningsStore preview and out-of-process")
@MainActor
struct EarningsStorePreviewTests {
    @Test("preview values a draft through the same ledger and publishes nothing")
    func previewDoesNotPublish() async {
        let source = FakeSource()
        let store = EarningsStore(source: source, debounceNanoseconds: 0, observesTriggers: false)
        await store.rebuildNow()
        let committed = store.snapshot!

        // W1's dinner shift grows from 330 to 390 minutes. The week is still
        // under the 2400-minute threshold, so this is all straight time.
        // The regular stream's cumulative over 255 + 390 = 645 minutes is
        // 283 * 645 * 100 = 18_253_500 units; roundCents is
        // (2 * 18_253_500 + 6000) / 12000 = 3042 (the exact 3042.25 rounds
        // down half-up). Lunch keeps the 1203 it was allocated first, so
        // dinner takes 3042 - 1203 = 1839.
        var draft = w1Inputs().shifts[1]
        draft.minutesWorked = 390
        let preview = store.preview(draft: draft)

        #expect(preview?.shift(shiftID(2))?.knownComponents.regularWagesCents == 1_839)
        #expect(preview?.shift(shiftID(1))?.knownComponents.regularWagesCents == 1_203,
                "an earlier shift never moves")
        #expect(store.snapshot?.stamp == committed.stamp, "the preview published nothing")
        #expect(store.publishedCount == 1)

        // A draft for a shift that does not exist yet is appended.
        let brandNew = ShiftInput(id: shiftID(9), workDay: day(2026, 9, 30), minutesWorked: 60)
        #expect(store.preview(draft: brandNew)?.shift(shiftID(9)) != nil)
    }

    @Test("preview is nil before the first successful build")
    func previewNeedsInputs() {
        let store = EarningsStore(source: FakeSource(), debounceNanoseconds: 0, observesTriggers: false)
        #expect(store.preview(draft: w1Inputs().shifts[0]) == nil)
    }

    @Test("buildOnce returns a snapshot for an out-of-process caller")
    func buildOnceSucceeds() {
        let result = EarningsStore.buildOnce(source: FakeSource())
        guard case .success(let snapshot) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(snapshot.stamp.generation == 0, "an out-of-process build has no generation to order")
        #expect(snapshot.shifts.count == 2)
    }

    @Test("buildOnce reports a fetch failure instead of an empty snapshot")
    func buildOnceFailsLoudly() {
        let source = FakeSource()
        source.nextFetchThrows = true
        let result = EarningsStore.buildOnce(source: source)
        guard case .failure(let reason) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        if case .fetchFailed = reason {} else {
            Issue.record("expected .fetchFailed, got \(reason)")
        }
    }

    /// The measured downgrade: a build whose schema omits `ShiftRecord`
    /// opens the same store file and Core Data purges every shift row while
    /// `TipEntry` survives. Re-upgrading finds zero shifts and a complete
    /// tip history, through no sync event at all. Publishing zeros there is
    /// the worst available answer.
    @Test("a wiped shift cache publishes .unavailable and asks for a baseline")
    func wipedCacheAsksForABaseline() async {
        var empty = w1Inputs()
        empty.shifts = []
        let source = FakeSource(inputs: empty, legacyTipEntryCount: 42)
        var baselineRequests = 0
        let store = EarningsStore(
            source: source,
            debounceNanoseconds: 0,
            shiftsAreAuthoritative: { true },
            requestShiftBaseline: { baselineRequests += 1 },
            observesTriggers: false
        )

        await store.rebuildNow()

        #expect(store.state == .unavailable(.shiftCacheWiped, last: nil))
        #expect(store.publishedCount == 0, "a zero total is never published for a purged cache")
        #expect(baselineRequests == 1)

        // Repeated triggers ask once, not once per trigger.
        await store.rebuildNow()
        #expect(baselineRequests == 1)

        // And the baseline arriving clears it.
        source.fetch = EarningsFetch(inputs: w1Inputs(), legacyTipEntryCount: 42)
        await store.rebuildNow()
        #expect(store.publishedCount == 1)
        #expect(store.snapshot?.shifts.count == 2)
    }

    /// The same shape BEFORE the conversion is ordinary, not a wipe: every
    /// existing user has legacy rows and no `ShiftRecord`s until PR 2's
    /// server conversion reaches them. Defaulting `shiftsAreAuthoritative`
    /// to false is what keeps this from blanking their screens.
    @Test("zero shifts next to legacy rows is not a wipe before the conversion")
    func preConversionEmptinessIsNotAWipe() async {
        var empty = w1Inputs()
        empty.shifts = []
        let source = FakeSource(inputs: empty, legacyTipEntryCount: 42)
        var baselineRequests = 0
        let store = EarningsStore(
            source: source,
            debounceNanoseconds: 0,
            requestShiftBaseline: { baselineRequests += 1 },
            observesTriggers: false
        )

        await store.rebuildNow()

        #expect(baselineRequests == 0)
        #expect(store.publishedCount == 1)
        #expect(store.snapshot?.completeness.state == .noShifts,
                "an empty dataset is .noShifts, which renders no currency at all")
    }

    /// A genuinely new account: no shifts and no legacy rows either.
    @Test("a brand-new account publishes an empty snapshot")
    func newAccountPublishesEmpty() async {
        var empty = w1Inputs()
        empty.shifts = []
        let store = EarningsStore(
            source: FakeSource(inputs: empty, legacyTipEntryCount: 0),
            debounceNanoseconds: 0,
            shiftsAreAuthoritative: { true },
            observesTriggers: false
        )
        await store.rebuildNow()
        #expect(store.publishedCount == 1)
        #expect(store.snapshot?.completeness.state == .noShifts)
    }
}

// MARK: - The real SwiftData source

@Suite("ModelContextEarningsInputSource")
@MainActor
struct ModelContextEarningsInputSourceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// End to end over real SwiftData: two stored records become a snapshot
    /// whose numbers are W1's.
    @Test("the real source reads shifts, paychecks and the legacy count")
    func readsTheRealStore() throws {
        let container = try container()
        let context = ModelContext(container)
        context.insert(ShiftRecord(
            id: shiftID(1), workDate: instant(2026, 9, 28), shiftPeriod: .lunch,
            creditTipsCents: 5_000, hoursWorked: 4.25
        ))
        context.insert(ShiftRecord(
            id: shiftID(2), workDate: instant(2026, 9, 28, hour: 18), shiftPeriod: .dinner,
            creditTipsCents: 6_000, hoursWorked: 5.5
        ))
        context.insert(PaycheckRecord(
            periodStart: instant(2026, 9, 21), periodEnd: instant(2026, 10, 4),
            paidTipsCents: 10_000
        ))
        context.insert(TipEntry(date: instant(2026, 9, 28), amountCents: 5_000, kind: .credit))
        try context.save()

        let source = ModelContextEarningsInputSource(
            context: context,
            policies: { CompensationPolicies(rates: [ratePolicy], calendars: [calendarPolicy]) },
            schedule: { PaySchedule(frequency: .biweekly, anchorPeriodEnd: instant(2026, 10, 4),
                                    payDelayDays: 5, firstWeekday: 2) },
            now: { instant(2026, 10, 2) }
        )
        let fetch = try source.fetchInputs()

        #expect(fetch.inputs.shifts.count == 2)
        #expect(fetch.inputs.paychecks.count == 1)
        #expect(fetch.legacyTipEntryCount == 1)
        #expect(fetch.inputs.asOf == day(2026, 10, 2))
        #expect(fetch.inputs.schedule?.frequency == "biweekly")
        #expect(fetch.inputs.schedule?.anchorPeriodEnd == day(2026, 10, 4))
        #expect(fetch.inputs.schedule?.firstWeekday == 2)
        #expect(fetch.inputs.rates == [ratePolicy])

        let snapshot = try EarningsSnapshot.build(fetch.inputs, generation: 1)
        // W1: 255 + 330 minutes at 283c -> 1203 + 1556 = 2759, plus 11000
        // of credit tips.
        #expect(snapshot.day(day(2026, 9, 28)).knownComponents.wagesCents == 2_759)
        #expect(snapshot.shift(shiftID(1))?.knownComponents.regularWagesCents == 1_203)
        #expect(snapshot.shift(shiftID(2))?.knownComponents.regularWagesCents == 1_556)
        #expect(snapshot.day(day(2026, 9, 28)).knownComponents.earnedIncomeCents == 13_759)
        #expect(snapshot.completeness.state == .complete)
    }

    @Test("a closed store is a refusal, not an empty snapshot")
    func closedStoreRefuses() throws {
        let container = try container()
        let source = ModelContextEarningsInputSource(
            context: ModelContext(container),
            policies: { CompensationPolicies(rates: [ratePolicy], calendars: [calendarPolicy]) },
            schedule: { nil },
            storeOpened: false
        )
        #expect(throws: ModelContextEarningsInputSource.StoreUnavailable.self) {
            try source.fetchInputs()
        }
    }

    /// The schedule's `firstWeekday` must travel as the RAW optional. The
    /// resolved value reads `Calendar.current.firstWeekday`, so digesting it
    /// would make two devices holding identical data disagree about the
    /// fingerprint of that data.
    @Test("an unset firstWeekday stays nil in the manifest, never the device's locale")
    func firstWeekdayIsNotResolved() throws {
        let container = try container()
        let source = ModelContextEarningsInputSource(
            context: ModelContext(container),
            policies: { CompensationPolicies(rates: [], calendars: [calendarPolicy]) },
            schedule: { PaySchedule(frequency: .weekly, anchorPeriodEnd: instant(2026, 10, 4),
                                    payDelayDays: nil, firstWeekday: nil) },
            now: { instant(2026, 10, 2) }
        )
        let fetch = try source.fetchInputs()
        #expect(fetch.inputs.schedule?.firstWeekday == nil)
        #expect(fetch.inputs.schedule?.payDelayDays == 0, "an unset delay resolves to 0, as it always did")
    }
}
