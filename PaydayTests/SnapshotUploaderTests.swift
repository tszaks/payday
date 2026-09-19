import Foundation
import Testing
import PaydayCore
@testable import Payday

/// PR 6 / 2.14 part 2c: when the device may publish the engine's answer,
/// and when it must refuse.
///
/// Every test here is about the REFUSALS. The happy path is one line; the
/// value of the type is the cases where it declines, because each of those
/// is a way the server would otherwise store a figure that disagrees with
/// the app.
@Suite("Snapshot uploader")
@MainActor
struct SnapshotUploaderTests {
    private static let zone = TimeZone(identifier: "America/New_York")!

    private func snapshot(cashCents: Int = 5_000) throws -> EarningsSnapshot {
        let day = CivilDay(year: 2026, month: 9, day: 14)
        return try EarningsSnapshot.build(
            EarningsInputs(
                shifts: [ShiftInput(
                    id: UUID(),
                    workDay: day,
                    period: nil,
                    recordedAt: Date(timeIntervalSince1970: 1_789_000_000),
                    voluntaryCashCents: cashCents,
                    voluntaryCreditCents: 0,
                    gratuityFeesCents: 0,
                    tipOutCents: nil,
                    minutesWorked: 300
                )],
                paychecks: [],
                schedule: PayScheduleInput(
                    frequency: "biweekly",
                    anchorPeriodEnd: CivilDay(year: 2026, month: 10, day: 4),
                    payDelayDays: 0
                ),
                rates: [],
                calendars: [PayrollCalendarPolicy(
                    id: PolicyMigration.deterministicID("uploader/calendar"),
                    effectiveFrom: .distantPast,
                    workweekStartWeekday: 2,
                    payrollTimeZone: Self.zone
                )],
                asOf: day
            ),
            generation: 0,
            computedAt: Date(timeIntervalSince1970: 1_789_000_000)
        )
    }

    private func user(withRevision revision: Int64?) -> UUID {
        let id = UUID()
        PaydaySyncState.applySyncedDatasetRevision(
            revision, clean: revision != nil, for: id)
        return id
    }

    /// **The refusal that the server cannot make for us.** A local write not
    /// yet pushed leaves the server's revision unmoved, so a snapshot built
    /// from unsynced rows would carry a stamp the RPC still considers
    /// current and would be ACCEPTED. Only the device knows it has unsent
    /// work, so only the device can decline.
    @Test("no clean sync means no upload, and no request at all")
    func refusesWithoutACleanSync() async throws {
        let id = user(withRevision: nil)
        var called = false
        let outcome = await SnapshotUploader().publish(try snapshot(), for: id) { _, _, _, _, _ in
            called = true
            return "accepted"
        }
        #expect(outcome == .skippedNoCleanSync)
        #expect(!called, "refusing means not spending the round trip either")
    }

    @Test("a clean sync publishes, stamped with the observed revision")
    func publishesWhenClean() async throws {
        let id = user(withRevision: 12)
        var seenRevision: Int64?
        let outcome = await SnapshotUploader().publish(try snapshot(), for: id) { rev, _, _, _, _ in
            seenRevision = rev
            return "accepted"
        }
        #expect(outcome == .uploaded(revision: 12))
        #expect(seenRevision == 12, "the stamp is the watermark, never a local clock")
    }

    /// Revision 0 is the real watermark of an account nothing has written
    /// for. Treating it as "no clean sync" would leave a new account
    /// permanently unable to publish, because 0 is the only revision its
    /// snapshot can ever match.
    @Test("revision zero publishes")
    func zeroPublishes() async throws {
        let id = user(withRevision: 0)
        let outcome = await SnapshotUploader().publish(try snapshot(), for: id) { _, _, _, _, _ in
            "accepted"
        }
        #expect(outcome == .uploaded(revision: 0))
    }

    /// Losing a race with another device is ordinary. It must not be
    /// reported as a failure, and it must not clear the watermark -- the
    /// watermark is about LOCAL cleanliness, which a lost race says nothing
    /// about.
    @Test("stale_input is an ordinary outcome and leaves the watermark alone")
    func staleIsOrdinary() async throws {
        let id = user(withRevision: 3)
        let outcome = await SnapshotUploader().publish(try snapshot(), for: id) { _, _, _, _, _ in
            "stale_input"
        }
        #expect(outcome == .stale)
        #expect(PaydaySyncState.snapshot(for: id).syncedDatasetRevision == 3,
                "a lost race is not evidence of local change")
    }

    /// An unrecognised verdict is a contract change. Treating an unknown
    /// string as success is how a future server-side rename would silently
    /// stop publishing while every device reported that it had.
    @Test("an unknown verdict is a failure, never a success")
    func unknownVerdictFails() async throws {
        let id = user(withRevision: 4)
        let outcome = await SnapshotUploader().publish(try snapshot(), for: id) { _, _, _, _, _ in
            "ok"
        }
        #expect(outcome == .failed)
    }

    @Test("an identical document is not re-sent")
    func identicalDocumentIsSkipped() async throws {
        let id = user(withRevision: 5)
        let uploader = SnapshotUploader()
        let snap = try snapshot()
        var calls = 0
        let first = await uploader.publish(snap, for: id) { _, _, _, _, _ in
            calls += 1; return "accepted"
        }
        let second = await uploader.publish(snap, for: id) { _, _, _, _, _ in
            calls += 1; return "accepted"
        }
        #expect(first == .uploaded(revision: 5))
        #expect(second == .skippedUnchanged)
        #expect(calls == 1)
    }

    /// Changed data must republish even at the same revision -- otherwise an
    /// edit that has already synced would never reach the server's stored
    /// answer.
    @Test("a different document at the same revision does republish")
    func changedDocumentRepublishes() async throws {
        let id = user(withRevision: 6)
        let uploader = SnapshotUploader()
        var calls = 0
        _ = await uploader.publish(try snapshot(cashCents: 1_000), for: id) { _, _, _, _, _ in
            calls += 1; return "accepted"
        }
        let second = await uploader.publish(try snapshot(cashCents: 2_000), for: id) { _, _, _, _, _ in
            calls += 1; return "accepted"
        }
        #expect(second == .uploaded(revision: 6))
        #expect(calls == 2)
    }

    /// A rejected upload must not be remembered as sent, or the retry after
    /// the next sync would be skipped as "unchanged" and the server would
    /// keep a stale answer forever.
    @Test("a stale upload is not remembered as sent")
    func staleIsNotRemembered() async throws {
        let id = user(withRevision: 7)
        let uploader = SnapshotUploader()
        let snap = try snapshot()
        var calls = 0
        _ = await uploader.publish(snap, for: id) { _, _, _, _, _ in
            calls += 1; return "stale_input"
        }
        let retry = await uploader.publish(snap, for: id) { _, _, _, _, _ in
            calls += 1; return "accepted"
        }
        #expect(retry == .uploaded(revision: 7))
        #expect(calls == 2, "the retry must actually be attempted")
    }
}
