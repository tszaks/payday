import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// Scenario C of `StoredDayTests`, through the real sync: a new phone east of
/// the account's payroll zone. It holds its first-launch policy (its own
/// zone) when the shifts and paychecks arrive, and the account's policies
/// arrive in the same pass, after them.
///
/// An extension of `SyncPassOrderTests` so these passes share its
/// `.serialized` trait and its one static `RoutingStub`.
extension SyncPassOrderTests {
    private static let storedDayUser = UUID(uuidString: "90000000-0000-4000-8000-0000000000d1")!
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static let accountPolicies = CompensationPolicies(
        rates: [],
        calendars: [PayrollCalendarPolicy(
            id: UUID(uuidString: "90000000-0000-4000-8000-0000000000d2")!,
            effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: losAngeles)])

    private static let serverDays = (13...19).map { "2026-07-\($0)" }
    private static let paycheckID = UUID(uuidString: "90000000-0000-4000-8000-0000000000d3")!

    private static func shiftID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "90000000-0000-4000-8000-0000000001%02d", index))!
    }

    private static func settingsRow() throws -> String {
        let policies = String(decoding: try JSONEncoder().encode(accountPolicies), as: UTF8.self)
        return """
            {"user_id":"\(storedDayUser.uuidString)","base_hourly_wage_cents":null,
             "smart_nudge_enabled":true,"payday_reminder_enabled":true,"move_ledger":{},
             "compensation_policies":\(policies),
             "client_updated_at":"2026-09-18T00:00:00.000Z","updated_at":"2026-09-18T00:00:00.000Z"}
            """
    }

    private static let paycheckRow = """
        {"id":"\(paycheckID.uuidString)","user_id":"\(storedDayUser.uuidString)",
         "period_start":"2026-07-13","period_end":"2026-07-19","paid_tips_cents":7000,
         "client_updated_at":"2026-09-18T00:00:00.000Z","deleted_at":null,
         "updated_at":"2026-09-18T00:00:00.000Z"}
        """

    private static func shiftRows() -> String {
        serverDays.enumerated().map { index, day in
            """
            {"id":"\(shiftID(index).uuidString)","user_id":"\(storedDayUser.uuidString)",
             "work_date":"\(day)","cash_tips_cents":1000,"credit_tips_cents":0,
             "client_updated_at":"2026-09-18T00:00:00.000Z",
             "updated_at":"2026-09-18T00:00:00.000Z","deleted_at":null}
            """
        }.joined(separator: ",")
    }

    private static func freshDefaults() -> UserDefaults {
        let suiteName = "com.szakacsmedia.payday.storeddaysynctests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("C: a new phone east of the payroll zone ends the sync with every day right and nothing to upload")
    func newPhoneEastOfThePayrollZone() async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.storedDayUser)
        defer { PaydaySyncState.forget(userID: Self.storedDayUser) }
        // A fresh install has never edited a setting.
        PaydaySettingsSyncClock.acceptRemoteTimestamp(Date(timeIntervalSince1970: 0))
        RoutingStub.route("/rest/v1/user_settings", to: try Self.settingsRow())
        RoutingStub.route("/rest/v1/paycheck_records", to: "[\(Self.paycheckRow)]")
        RoutingStub.route(
            "/rpc/fetch_shift_changes",
            to: "{\"server_now\":\"2026-09-19T00:00:00.000Z\",\"rows\":[\(Self.shiftRows())]}")

        let context = try context()
        let policyStore = PolicyStore(defaults: Self.freshDefaults())
        // The first-launch policy: the phone's own zone, Tokyo.
        policyStore.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil, baseHourlyWageCents: nil, deviceTimeZone: Self.tokyo)
        #expect(policyStore.payrollTimeZone == Self.tokyo)

        _ = try await PaydaySyncService(client: client).synchronize(
            context: context,
            scheduleStore: PayScheduleStore(defaults: Self.freshDefaults()),
            preferencesStore: UserPreferencesStore(defaults: Self.freshDefaults(), wageDefaults: Self.freshDefaults()),
            moveLedgerStore: MoveLedgerStore(defaults: Self.freshDefaults()),
            policyStore: policyStore,
            userID: Self.storedDayUser
        )
        #expect(policyStore.payrollTimeZone == Self.losAngeles, "precondition: the account's policies arrived")

        let calendars = policyStore.policies.calendars
        let shifts = try context.fetch(FetchDescriptor<ShiftRecord>()).sorted { $0.workDate < $1.workDate }
        #expect(shifts.count == Self.serverDays.count)
        #expect(ShiftInputAdapter.inputs(from: shifts, calendars: calendars).map(\.workDay.iso) == Self.serverDays)
        let check = try #require(try context.fetch(FetchDescriptor<PaycheckRecord>()).first)
        let paychecks = PaycheckInputAdapter.inputs(from: [check], calendars: calendars)
        #expect(paychecks.map(\.periodStart.iso) == ["2026-07-13"])
        #expect(paychecks.map(\.periodEnd.iso) == ["2026-07-19"])

        // Nothing is in the upload set.
        let checkpoint = PaydaySyncState.snapshot(for: Self.storedDayUser)
        #expect(PaydaySyncState.changedIDs(
            current: try PaydayRowFingerprint.values(shifts),
            acknowledged: checkpoint.shiftContentFingerprint).isEmpty)
        #expect(PaydaySyncState.changedIDs(
            current: try PaydayRowFingerprint.values([check]),
            acknowledged: checkpoint.paycheckContentFingerprint).isEmpty)
    }

    /// The same order on the first sign-in, which downloads paychecks and
    /// settings through `reconcile(snapshot:)`.
    @Test("C: the first sign-in stores a paycheck in the account's zone when the policies arrive after it")
    func firstSignInEastOfThePayrollZone() throws {
        PaydaySettingsSyncClock.acceptRemoteTimestamp(Date(timeIntervalSince1970: 0))
        let decoder = JSONDecoder()
        let snapshot = PaydayRemoteSnapshot(
            tips: [],
            paychecks: [try decoder.decode(RemotePaycheckRecord.self, from: Data(Self.paycheckRow.utf8))],
            settings: try decoder.decode(RemoteUserSettings.self, from: Data(try Self.settingsRow().utf8)))
        let context = try context()
        let policyStore = PolicyStore(defaults: Self.freshDefaults())
        policyStore.runMigrationsIfNeeded(
            resolvedFirstWeekday: 2, earliestShiftDate: nil, baseHourlyWageCents: nil, deviceTimeZone: Self.tokyo)

        _ = try PaydaySyncService.reconcile(
            snapshot: snapshot,
            context: context,
            scheduleStore: PayScheduleStore(defaults: Self.freshDefaults()),
            preferencesStore: UserPreferencesStore(defaults: Self.freshDefaults(), wageDefaults: Self.freshDefaults()),
            moveLedgerStore: MoveLedgerStore(defaults: Self.freshDefaults()),
            policyStore: policyStore,
            forceRemoteRows: true,
            forceRemoteSettings: true
        )
        #expect(policyStore.payrollTimeZone == Self.losAngeles)
        let check = try #require(try context.fetch(FetchDescriptor<PaycheckRecord>()).first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.losAngeles
        #expect(check.periodStart == calendar.date(from: DateComponents(year: 2026, month: 7, day: 13)))
        #expect(check.periodEnd == calendar.date(from: DateComponents(year: 2026, month: 7, day: 19)))
    }
}
