import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Flip gate 1, landed ahead of the flip so the property is proven rather than
/// invented alongside the change that depends on it.
///
/// `BackfillSheet` and `LogTipSheet` pass `allEntries + sessionEntries` /
/// `+ newEntries` to the schedulers, because `@Query` has not refreshed by the
/// time `onDisappear` fires. When the writer flips, those additions must become
/// `shiftRecords + the records just created`. If that is missed, the user logs a
/// shift and the very next thing the app does is tell them "you haven't logged
/// today" -- the bug #40 switched this scheduler to prevent, reintroduced from
/// the other side.
///
/// This suite asserts the receiving end is ready: a `ShiftRecord` handed in
/// alongside the queried ones suppresses tonight's nudge exactly as a queried
/// one would. So at flip time the only thing left to get right is passing it,
/// and gate 1 is a check on the call site rather than on the mechanism.
@Suite("Flip gate 1: logged this session", .serialized)
@MainActor
struct FlipGate1SessionLoggedTests {

    private func authoritativeAccount() -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        PaydaySyncState.mutate(userID: id) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }
        #expect(PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)
        return id
    }

    private static let calendar = Calendar.current

    /// 20:00, so tonight's 22:45 fire time has not passed.
    private static let now = calendar.date(
        bySettingHour: 20, minute: 0, second: 0,
        of: Date(timeIntervalSince1970: 1_790_000_000)
    )!

    /// Five prior weeks on the same weekday at 22:00, which is what
    /// `workRhythm` needs to call this a usual night with a typical hour.
    private static func history() -> [ShiftRecord] {
        (1...5).compactMap { week -> ShiftRecord? in
            guard let day = calendar.date(
                byAdding: .day, value: -7 * week, to: calendar.startOfDay(for: now)
            ) else { return nil }
            return ShiftRecord(
                workDate: day, cashTipsCents: 9_000, hoursWorked: 6,
                recordedAt: calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
            )
        }
    }

    /// The gate. A record created in this session — never returned by
    /// `@Query` — must satisfy the "already logged tonight" check.
    @Test("a shift logged this session, absent from the query, suppresses tonight's nudge")
    func sessionLoggedShiftSuppressesTonight() {
        _ = authoritativeAccount()

        // What `@Query` would return: history only. Tonight is unlogged, so
        // the nudge is tonight.
        let queried = Self.history()
        let beforeLogging = SmartNudgeScheduler.rhythmFireDate(
            allEntries: [], shiftRecords: queried, from: Self.now
        )
        let tonight = try? #require(beforeLogging)
        #expect(tonight != nil, "the fixture must produce a nudge, or this proves nothing")
        if let tonight {
            #expect(Self.calendar.isDate(tonight, inSameDayAs: Self.now))
        }

        // The just-created record, appended the way the call site must append
        // it. `@Query` has not refreshed, so `queried` is unchanged.
        let justCreated = ShiftRecord(
            workDate: Self.calendar.startOfDay(for: Self.now),
            cashTipsCents: 9_000, hoursWorked: 6, recordedAt: Self.now
        )
        let afterLogging = SmartNudgeScheduler.rhythmFireDate(
            allEntries: [], shiftRecords: queried + [justCreated], from: Self.now
        )

        // Tonight is now logged, so the nudge moves off tonight.
        #expect(afterLogging != beforeLogging)
        if let afterLogging {
            #expect(!Self.calendar.isDate(afterLogging, inSameDayAs: Self.now),
                    "a shift logged this session must not still be nudged for")
        }
    }

    /// The failure this gate exists to prevent, stated as its own assertion:
    /// forgetting to append leaves the user nudged for a shift they just
    /// logged. Asserted so the gate has a named counterexample rather than
    /// only a happy path.
    @Test("forgetting to append the session's record is what reintroduces the bug")
    func forgettingToAppendReintroducesTheBug() {
        _ = authoritativeAccount()
        let queried = Self.history()

        // The wrong call: the record exists in the store but was not handed
        // in, and `@Query` has not caught up.
        let forgotten = SmartNudgeScheduler.rhythmFireDate(
            allEntries: [], shiftRecords: queried, from: Self.now
        )
        let appended = SmartNudgeScheduler.rhythmFireDate(
            allEntries: [], shiftRecords: queried + [ShiftRecord(
                workDate: Self.calendar.startOfDay(for: Self.now),
                cashTipsCents: 9_000, hoursWorked: 6, recordedAt: Self.now
            )], from: Self.now
        )

        // They differ, and the forgotten one is tonight. That is the bug.
        #expect(forgotten != appended)
        if let forgotten {
            #expect(Self.calendar.isDate(forgotten, inSameDayAs: Self.now),
                    "without the append, tonight is still nudged for")
        }
    }
}
