import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// A person's compensation policies (rate history, role rates, the job list,
/// the payroll zone) must follow them to another phone, and a phone's real
/// policies must never be replaced by another phone's untouched defaults.
///
/// An extension of `SyncPassOrderTests` so these passes share its
/// `.serialized` trait: every pass here goes through the one static
/// `RoutingStub`, and the settings clock lives in the App Group, so two
/// passes interleaving would read each other's answers.
extension SyncPassOrderTests {

    /// Its own account, so a checkpoint another test left behind cannot
    /// change what these passes see. `forget(userID:)` clears it per test.
    private static let policyUser = UUID(uuidString: "90000000-0000-4000-8000-0000000000e1")!
    private static let chicago = TimeZone(identifier: "America/Chicago")!

    /// Policies a person authored on phone A: a dated raise, a role rate,
    /// two jobs, and New York as the payroll zone. The second job has a
    /// calendar of its own, so a download stores exactly this value.
    private static let realPolicies = CompensationPolicies(
        rates: [
            PayRatePolicy(
                id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f1")!,
                effectiveFrom: CivilDay(year: 2026, month: 1, day: 5),
                hourlyRateCents: 1_500, provenance: .confirmed),
            PayRatePolicy(
                id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f2")!,
                effectiveFrom: CivilDay(year: 2026, month: 6, day: 1),
                hourlyRateCents: 1_750, provenance: .confirmed),
            PayRatePolicy(
                id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f3")!,
                effectiveFrom: CivilDay(year: 2026, month: 1, day: 5),
                hourlyRateCents: 900, provenance: .confirmed, roleName: "Bar"),
        ],
        calendars: [
            PayrollCalendarPolicy(
                id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f4")!,
                effectiveFrom: .distantPast, workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.newYork),
            PayrollCalendarPolicy(
                id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f5")!,
                effectiveFrom: .distantPast, workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.newYork, jobName: "Cafe"),
        ],
        jobs: [
            JobPolicy(id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f6")!,
                      name: "Bistro", schedule: nil, isPrimary: true),
            JobPolicy(id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f7")!,
                      name: "Cafe", schedule: nil, isPrimary: false),
        ])

    /// What `PolicyStore.runMigrationsIfNeeded` adopts on a phone in Chicago
    /// that has the legacy wage and nothing else.
    private static let chicagoDefaults = CompensationPolicies(
        rates: [PolicyMigration.assumedRatePolicy(hourlyRateCents: 1_750, earliestShiftDay: nil)],
        calendars: [PolicyMigration.frozenCalendarPolicy(workweekStartWeekday: 1, payrollTimeZone: chicago)])

    /// One phone's stores, each on a defaults suite of its own, so nothing
    /// here reads or writes the simulator's real settings except the
    /// settings clock, which exists only in the App Group.
    @MainActor
    private struct Phone {
        let context: ModelContext
        let schedule = PayScheduleStore(defaults: Phone.freshDefaults())
        let preferences = UserPreferencesStore(defaults: Phone.freshDefaults(), wageDefaults: Phone.freshDefaults())
        let moveLedger = MoveLedgerStore(defaults: Phone.freshDefaults())
        let policies = PolicyStore(defaults: Phone.freshDefaults())

        private static func freshDefaults() -> UserDefaults {
            let suiteName = "com.szakacsmedia.payday.policysynctests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }

        /// The launch adoption on a phone that has only the legacy wage.
        func adoptDefaults() {
            policies.runMigrationsIfNeeded(
                resolvedFirstWeekday: 1, earliestShiftDate: nil,
                baseHourlyWageCents: 1_750, deviceTimeZone: SyncPassOrderTests.chicago)
        }

        /// One regular sync pass.
        func sync(with service: PaydaySyncService) async throws {
            _ = try await service.synchronize(
                context: context,
                scheduleStore: schedule,
                preferencesStore: preferences,
                moveLedgerStore: moveLedger,
                policyStore: policies,
                userID: SyncPassOrderTests.policyUser
            )
        }

        /// What `PaydayMigrationService.migrate` does on a first sign-in once
        /// its insert-only import is done: read the snapshot, reconcile with
        /// the server's settings forced, and record the checkpoint.
        func firstSignIn(with repository: PaydayRemoteRepository) async throws {
            let snapshot = try await repository.fetchSnapshot(userID: SyncPassOrderTests.policyUser)
            _ = try PaydaySyncService.reconcile(
                snapshot: snapshot,
                context: context,
                scheduleStore: schedule,
                preferencesStore: preferences,
                moveLedgerStore: moveLedger,
                policyStore: policies,
                forceRemoteRows: true,
                forceRemoteSettings: true
            )
            PaydaySyncState.mutate(userID: SyncPassOrderTests.policyUser) { checkpoint in
                checkpoint.migrationVerified = true
                checkpoint.settingsClientUpdatedAt = snapshot.settings.clientUpdatedAt
                checkpoint.settingsServerUpdatedAt = snapshot.settings.serverUpdatedAt
            }
        }
    }

    /// The server's `user_settings` row, with `policies` as the raw JSON of
    /// its `compensation_policies` column.
    private static func serverRow(policies: String, clientUpdatedAt: Date) -> String {
        let stamp = PaydayRemoteDate.instant(clientUpdatedAt)
        return """
            {"user_id":"\(policyUser.uuidString)","base_hourly_wage_cents":1750,
             "smart_nudge_enabled":true,"payday_reminder_enabled":true,"move_ledger":{},
             "compensation_policies":\(policies),
             "client_updated_at":"\(stamp)","updated_at":"\(stamp)"}
            """
    }

    private static func json(_ policies: CompensationPolicies) throws -> String {
        String(decoding: try JSONEncoder().encode(policies), as: UTF8.self)
    }

    /// The policies of every `upsert_user_settings` call so far, in order.
    private static func uploadedPolicies() throws -> [CompensationPolicies?] {
        struct Upload: Decodable {
            let row: RemoteUserSettings
            enum CodingKeys: String, CodingKey { case row = "p_row" }
        }
        return try RoutingStub.recordedBodies("/rpc/upsert_user_settings").map {
            try JSONDecoder().decode(Upload.self, from: $0).row.compensationPolicies
        }
    }

    /// A phone that already holds `policies`, acknowledged, with its
    /// settings clock and checkpoint both at `clock`: an ordinary synced
    /// phone with nothing to upload.
    private func syncedPhone(holding policies: CompensationPolicies, clock: Date) throws -> Phone {
        let phone = Phone(context: try context())
        phone.policies.replaceFromSupabase(policies)
        PaydaySettingsSyncClock.acceptRemoteTimestamp(clock)
        PaydaySyncState.mutate(userID: Self.policyUser) {
            $0.settingsClientUpdatedAt = PaydayRemoteDate.instant(clock)
        }
        return phone
    }

    // MARK: - Download

    /// Phone B is new: it adopted Chicago defaults at launch, and the server
    /// holds what the person built on phone A. B must end with A's policies
    /// and must never send its defaults over them.
    @Test("a new phone takes the server's policies at sign-in and never uploads its defaults")
    func aNewPhoneTakesTheServersPolicies() async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.policyUser)
        // A fresh install has never edited a setting.
        PaydaySettingsSyncClock.acceptRemoteTimestamp(Date(timeIntervalSince1970: 0))
        let phone = Phone(context: try context())
        phone.adoptDefaults()
        #expect(phone.policies.policies == Self.chicagoDefaults)
        #expect(phone.policies.adoptedPoliciesAwaitingUpload, "precondition: the adoption is waiting to upload")
        RoutingStub.route("/rest/v1/user_settings", to: Self.serverRow(
            policies: try Self.json(Self.realPolicies),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_758_240_000)))

        try await phone.firstSignIn(with: PaydayRemoteRepository(client: client))
        #expect(phone.policies.policies == Self.realPolicies, "the first sign-in did not download the policies")
        #expect(!phone.policies.adoptedPoliciesAwaitingUpload)

        // The gate adopts again after `restore`; with the server's policies
        // in place there is nothing left to adopt.
        phone.adoptDefaults()
        try await phone.sync(with: PaydaySyncService(client: client))

        #expect(phone.policies.policies == Self.realPolicies)
        #expect(phone.policies.payrollTimeZone == PaydayTestZone.newYork)
        #expect(!phone.policies.adoptedPoliciesAwaitingUpload)
        let uploads = try Self.uploadedPolicies()
        #expect(uploads.allSatisfy { $0 == Self.realPolicies }, "a settings upload carried other policies: \(uploads)")
    }

    /// Today's behaviour for an account whose server row has no policies:
    /// the phone keeps what it adopted and uploads it exactly once.
    @Test(
        "a server with no policies keeps the local defaults and receives them once",
        arguments: ["null", #"{"version":1,"rates":[],"calendars":[],"jobs":[]}"#]
    )
    func aServerWithNoPoliciesReceivesTheDefaultsOnce(serverPolicies: String) async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.policyUser)
        PaydaySettingsSyncClock.acceptRemoteTimestamp(Date(timeIntervalSince1970: 0))
        let phone = Phone(context: try context())
        phone.adoptDefaults()
        RoutingStub.route("/rest/v1/user_settings", to: Self.serverRow(
            policies: serverPolicies, clientUpdatedAt: Date(timeIntervalSince1970: 1_758_240_000)))

        try await phone.firstSignIn(with: PaydayRemoteRepository(client: client))
        #expect(phone.policies.policies == Self.chicagoDefaults)
        #expect(phone.policies.adoptedPoliciesAwaitingUpload)

        let service = PaydaySyncService(client: client)
        try await phone.sync(with: service)
        try await phone.sync(with: service)

        #expect(phone.policies.policies == Self.chicagoDefaults)
        #expect(!phone.policies.adoptedPoliciesAwaitingUpload)
        #expect(try Self.uploadedPolicies() == [Self.chicagoDefaults])
    }

    // MARK: - Which copy wins

    /// The repair. Another phone uploaded its untouched defaults without a
    /// newer settings clock, which is what an adoption upload looks like.
    /// This phone keeps its real policies and sends them back on its next
    /// pass.
    @Test("defaults uploaded without a newer clock do not replace real policies, and are repaired")
    func adoptionDefaultsDoNotReplaceRealPolicies() async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.policyUser)
        let clock = Date(timeIntervalSince1970: 1_758_240_000)
        let phone = try syncedPhone(holding: Self.realPolicies, clock: clock)
        RoutingStub.route("/rest/v1/user_settings", to: Self.serverRow(
            policies: try Self.json(Self.chicagoDefaults), clientUpdatedAt: clock))
        let service = PaydaySyncService(client: client)

        try await phone.sync(with: service)
        #expect(phone.policies.policies == Self.realPolicies, "the server's defaults replaced real policies")
        #expect(phone.policies.adoptedPoliciesAwaitingUpload, "the real policies were not marked for upload")

        try await phone.sync(with: service)
        let uploads = try Self.uploadedPolicies()
        #expect(uploads.last == Self.realPolicies, "the next pass did not send the real policies back: \(uploads)")
        #expect(!uploads.contains(Self.chicagoDefaults))
    }

    /// A real edit on another phone advances the settings clock, so it wins
    /// here the way every other setting does. The remote clock is in the
    /// future so no other suite's clock touch can make it look older.
    @Test("real policies with a newer clock replace this phone's")
    func newerRealPoliciesReplaceLocalOnes() async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.policyUser)
        let phone = try syncedPhone(holding: Self.realPolicies, clock: Date.now.addingTimeInterval(-86_400))
        let edited = Self.realPolicies.adding(rate: PayRatePolicy(
            id: UUID(uuidString: "90000000-0000-4000-8000-0000000000f8")!,
            effectiveFrom: CivilDay(year: 2026, month: 10, day: 1),
            hourlyRateCents: 2_000, provenance: .confirmed))
        RoutingStub.route("/rest/v1/user_settings", to: Self.serverRow(
            policies: try Self.json(edited), clientUpdatedAt: Date.now.addingTimeInterval(86_400)))

        try await phone.sync(with: PaydaySyncService(client: client))

        #expect(phone.policies.policies == edited)
        #expect(!phone.policies.adoptedPoliciesAwaitingUpload)
    }

    /// The wage was turned off on another phone: what is left looks like
    /// untouched defaults, but its clock is newer, so it is a real edit and
    /// it wins.
    @Test("defaults with a newer clock replace this phone's real policies")
    func newerDefaultsReplaceLocalOnes() async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.policyUser)
        let phone = try syncedPhone(holding: Self.realPolicies, clock: Date.now.addingTimeInterval(-86_400))
        RoutingStub.route("/rest/v1/user_settings", to: Self.serverRow(
            policies: try Self.json(Self.chicagoDefaults), clientUpdatedAt: Date.now.addingTimeInterval(86_400)))

        try await phone.sync(with: PaydaySyncService(client: client))

        #expect(phone.policies.policies == Self.chicagoDefaults)
        #expect(!phone.policies.adoptedPoliciesAwaitingUpload)
    }

    @Test("the same policies on both sides change nothing and upload nothing")
    func samePoliciesChangeNothing() async throws {
        let client = client()
        PaydaySyncState.forget(userID: Self.policyUser)
        let clock = Date(timeIntervalSince1970: 1_758_240_000)
        let phone = try syncedPhone(holding: Self.realPolicies, clock: clock)
        RoutingStub.route("/rest/v1/user_settings", to: Self.serverRow(
            policies: try Self.json(Self.realPolicies), clientUpdatedAt: clock))

        try await phone.sync(with: PaydaySyncService(client: client))

        #expect(phone.policies.policies == Self.realPolicies)
        #expect(!phone.policies.adoptedPoliciesAwaitingUpload)
        #expect(!RoutingStub.recordedPaths().contains("POST /rest/v1/rpc/upsert_user_settings"))
    }
}

/// What the settings read asks for and what it accepts back.
@Suite("Settings wire shape")
struct SettingsWireShapeTests {
    /// The server sends only the columns a read names, so a coding key the
    /// select list forgets decodes as nil on every device, forever, with no
    /// error anywhere. `compensation_policies` was missing exactly that way.
    @Test("the settings read names every column RemoteUserSettings decodes")
    func theSelectNamesEveryCodingKey() {
        let selected = Set(PaydayRemoteRepository.settingsColumns.split(separator: ",").map(String.init))
        let missing = RemoteUserSettings.CodingKeys.allCases.map(\.rawValue).filter { !selected.contains($0) }
        #expect(missing.isEmpty, "settingsColumns does not select \(missing)")
    }

    /// No shipped build has read this column back, so its stored content is
    /// unproven. A payload that does not decode must leave the local
    /// policies alone, not stop the whole settings row and with it every
    /// sync pass.
    @Test(
        "a compensation_policies value that does not decode reads as nil and the rest of the row survives",
        arguments: [
            #""not policies""#,
            #"{"version":1,"rates":[{"id":"90000000-0000-4000-8000-0000000000f1","effectiveFrom":"not-a-day","hourlyRateCents":1500,"provenance":"confirmed"}]}"#,
        ]
    )
    func aMalformedPoliciesValueReadsAsNil(policies: String) throws {
        let row = """
            {"user_id":"90000000-0000-4000-8000-0000000000e1","first_name":"Ana",
             "base_hourly_wage_cents":1750,"pay_frequency":"biweekly",
             "anchor_period_end":"2026-09-18","pay_delay_days":5,"first_weekday":2,
             "smart_nudge_enabled":false,"payday_reminder_enabled":true,
             "move_ledger":{"plan":"2026-09-01T00:00:00.000Z"},"card_tips_paid_at_close":true,
             "compensation_policies":\(policies),
             "client_updated_at":"2026-09-19T00:00:00.000Z","updated_at":"2026-09-19T00:00:01.000Z"}
            """

        let settings = try JSONDecoder().decode(RemoteUserSettings.self, from: Data(row.utf8))

        #expect(settings.compensationPolicies == nil)
        #expect(settings.userID == UUID(uuidString: "90000000-0000-4000-8000-0000000000e1"))
        #expect(settings.firstName == "Ana")
        #expect(settings.baseHourlyWageCents == 1_750)
        #expect(settings.payFrequency == "biweekly")
        #expect(settings.anchorPeriodEnd == "2026-09-18")
        #expect(settings.payDelayDays == 5)
        #expect(settings.firstWeekday == 2)
        #expect(settings.smartNudgeEnabled == false)
        #expect(settings.paydayReminderEnabled == true)
        #expect(settings.moveLedger == ["plan": "2026-09-01T00:00:00.000Z"])
        #expect(settings.cardTipsPaidAtClose == true)
        #expect(settings.clientUpdatedAt == "2026-09-19T00:00:00.000Z")
        #expect(settings.serverUpdatedAt == "2026-09-19T00:00:01.000Z")
    }
}
