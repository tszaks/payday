import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import OSLog
import Supabase
import SwiftData
import SwiftUI

@MainActor
@Observable
final class PaydayCloudState {
    private static let logger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "SupabaseSync"
    )
    enum Phase: Equatable {
        case loading
        case signedOut
        case migrating
        case ready(PaydayMigrationReport)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private let client: SupabaseClient
    private let migrationService: PaydayMigrationService
    private let syncService: PaydaySyncService
    private var isSyncing = false
    private var lastSyncAttemptAt: Date?
    private var nextSyncAllowedAt: Date?
    private var consecutiveSyncFailures = 0
    private var isOfflineUITest = false

    var isSynchronizing: Bool { isSyncing }

    init(client: SupabaseClient = PaydaySupabase.client) {
        self.client = client
        self.migrationService = PaydayMigrationService(client: client)
        self.syncService = PaydaySyncService(client: client)
    }

    func restore(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) async {
        #if DEBUG || targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-UITestOffline") {
            isOfflineUITest = true
            let previewUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            phase = .ready(
                (try? PaydaySyncService.cachedReport(context: context, userID: previewUserID))
                    ?? PaydayMigrationReport(
                        localTipEntryCount: 0,
                        localPaycheckCount: 0,
                        remoteTipEntryCount: 0,
                        remotePaycheckCount: 0,
                        tipEntryHash: "",
                        paycheckHash: ""
                    )
            )
            return
        }
        #endif
        // Checked before the session is even consulted. Sign-out is a
        // decision, not a connectivity state: an interrupted remote sign-out
        // can leave a usable local session behind, and the cached fallback
        // below would then restore full access to the financial cache on the
        // next cold launch. Cleared only by a fresh authentication.
        if PaydayAuthorizationState.isExplicitlySignedOut {
            phase = .signedOut
            return
        }

        let userID: UUID
        do {
            userID = try await client.auth.session.user.id
        } catch {
            // A verified account remains usable from its local cache even if
            // the JWT needs a network refresh. The periodic sync below will
            // retry quietly when connectivity returns. Reachable only when
            // the person did NOT ask to sign out — see the guard above.
            if let cachedUserID = PaydaySyncState.registeredUserID,
               PaydaySyncState.migrationIsVerified(for: cachedUserID),
               let report = try? PaydaySyncService.cachedReport(context: context, userID: cachedUserID) {
                phase = .ready(report)
            } else {
                phase = .signedOut
            }
            return
        }
        guard PaydaySyncState.registerCurrentUser(userID) else {
            phase = .failed(PaydayMigrationError.accountMismatch.localizedDescription)
            return
        }
        if PaydaySyncState.migrationIsVerified(for: userID) {
            do {
                phase = .ready(try PaydaySyncService.cachedReport(context: context, userID: userID))
            } catch {
                phase = .failed("Couldn't open your data.")
                return
            }
            await synchronize(
                context: context,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore,
                showProgress: false
            )
        } else {
            await migrate(
                context: context,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore
            )
        }
    }

    func signInWithApple(
        idToken: String,
        nonce: String,
        fullName: PersonNameComponents?,
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) async {
        phase = .migrating
        do {
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
            // The one thing allowed to lift an explicit sign-out.
            PaydayAuthorizationState.clearExplicitSignOut()
            if let firstName = AppleIdentityProfile.newFirstName(
                from: fullName,
                currentFirstName: preferencesStore.firstName
            ) {
                preferencesStore.firstName = firstName
            }
            if let fullName {
                let formatter = PersonNameComponentsFormatter()
                let renderedName = formatter.string(from: fullName)
                if !renderedName.isEmpty {
                    try await client.auth.update(
                        user: UserAttributes(data: ["full_name": .string(renderedName)])
                    )
                }
            }
            let userID = try await client.auth.session.user.id
            guard PaydaySyncState.registerCurrentUser(userID) else {
                throw PaydayMigrationError.accountMismatch
            }
            if PaydaySyncState.migrationIsVerified(for: userID) {
                phase = .ready(try PaydaySyncService.cachedReport(context: context, userID: userID))
                await synchronize(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    policyStore: policyStore,
                    showProgress: false
                )
            } else {
                await migrate(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    policyStore: policyStore
                )
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func retryMigration(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) async {
        do {
            let userID = try await client.auth.session.user.id
            if PaydaySyncState.migrationIsVerified(for: userID) {
                await synchronize(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    policyStore: policyStore,
                    showProgress: true
                )
            } else {
                await migrate(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    policyStore: policyStore
                )
            }
        } catch {
            phase = .signedOut
        }
    }

    func syncIfReady(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore,
        minimumInterval: TimeInterval? = 120
    ) async {
        guard case .ready = phase else { return }
        guard !isOfflineUITest else { return }
        let now = Date.now
        if let minimumInterval {
            guard lastSyncAttemptAt.map({ now.timeIntervalSince($0) >= minimumInterval }) ?? true else { return }
        }
        guard nextSyncAllowedAt.map({ now >= $0 }) ?? true else { return }
        lastSyncAttemptAt = now
        await synchronize(
            context: context,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore,
            policyStore: policyStore,
            showProgress: false
        )
    }

    /// Signs out and returns to the gate, leaving local data alone.
    ///
    /// Deliberately non-destructive: signing out is not deleting. The shifts
    /// stay on the device and sync back up on the next sign-in, which is
    /// what someone switching Apple IDs or handing over a demo device
    /// expects. See deleteAccount for the destructive path.
    func signOut() async {
        // Recorded first, deliberately. If this call throws, or the process is
        // killed mid-flight, the device must still come back signed out.
        PaydayAuthorizationState.markExplicitlySignedOut()
        // The widget renders from the shared store in its own process and
        // would otherwise keep printing the last period total on the Lock
        // Screen of a signed-out device.
        PaydayWidgetRefresh.request()
        do {
            try await client.auth.signOut()
        } catch {
            // A failed network sign-out still cleared the local session in
            // every case that matters; stranding the person on a screen they
            // asked to leave would be worse than proceeding.
            Self.logger.error("Sign out failed: \(String(describing: error), privacy: .public)")
        }
        phase = .signedOut
    }

    /// Deletes the account and everything in it, server and device.
    ///
    /// Required by App Review Guideline 5.1.1(v). The server side is one
    /// RPC: delete_my_account() removes the auth.users row and every Payday
    /// table cascades from it, so there is no per-table delete list here to
    /// drift out of sync with the schema.
    ///
    /// Server first, on purpose. If the RPC fails we stop and report it with
    /// the local data still intact, because the failure mode of the other
    /// order is the worst one available: a wiped phone still attached to a
    /// live account, with the person's records gone and nothing deleted
    /// where it counts.
    func deleteAccount(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        insightsStore: InsightsStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) async -> String? {
        do {
            try await client.rpc("delete_my_account").execute()
        } catch {
            Self.logger.error("Account deletion failed: \(String(describing: error), privacy: .public)")
            return Self.message(for: error)
        }

        // Captured before erasing, because the erase clears the registration
        // needed to forget the right user's sync state.
        let deletedUserID = PaydaySyncState.registeredUserID

        do {
            try PaydayAccountEraser.eraseLocalData(
                context: context,
                scheduleStore: scheduleStore,
                insightsStore: insightsStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore
            )
        } catch {
            // The remote account is gone but this device still holds
            // financial rows. Reporting success is the one outcome that is
            // definitely wrong: it tells someone their data is destroyed
            // while it is still sitting in the shared store.
            Self.logger.error("Local erase after account deletion failed: \(String(describing: error), privacy: .public)")
            return Self.localEraseFailureMessage
        }

        if let deletedUserID {
            PaydaySyncState.forget(userID: deletedUserID)
        }
        PaydayAuthorizationState.reset()

        // The account is already gone, so a failure here is cosmetic: there
        // is no session left to revoke server-side.
        try? await client.auth.signOut()
        phase = .signedOut
        return nil
    }

    /// Actionable rather than reassuring: the account really is deleted
    /// server-side, so the only useful next step is clearing the device.
    private static let localEraseFailureMessage = "Your account and its server data were deleted, but Payday could not finish clearing this device. Delete the app to remove the local copy."

    func showSignIn() {
        phase = .signedOut
    }

    private func migrate(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) async {
        phase = .migrating
        do {
            phase = .ready(try await migrationService.migrate(
                context: context,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore,
                deviceID: PaydayDeviceIdentity.current
            ))
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func synchronize(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore,
        showProgress: Bool
    ) async {
        guard !isSyncing else { return }
        lastSyncAttemptAt = .now
        isSyncing = true
        defer { isSyncing = false }
        if showProgress { phase = .migrating }
        let startedAt = Date.now
        do {
            var outcome = try await syncService.synchronize(
                context: context,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore
            )
            while outcome.requiresFollowUpSync {
                outcome = try await syncService.synchronize(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    policyStore: policyStore
                )
            }
            consecutiveSyncFailures = 0
            nextSyncAllowedAt = nil
            phase = .ready(outcome.report)
            Self.logger.notice(
                "Sync succeeded. elapsedMs=\(Int(Date.now.timeIntervalSince(startedAt) * 1_000))"
            )
        } catch {
            consecutiveSyncFailures += 1
            let exponent = min(consecutiveSyncFailures - 1, 5)
            let retryDelay = min(900.0, 30.0 * pow(2.0, Double(exponent)))
            nextSyncAllowedAt = Date.now.addingTimeInterval(retryDelay)
            Self.logger.error(
                "Sync failed. type=\(String(describing: type(of: error)), privacy: .public) elapsedMs=\(Int(Date.now.timeIntervalSince(startedAt) * 1_000)) retrySeconds=\(Int(retryDelay))"
            )
            if showProgress { phase = .failed(Self.message(for: error)) }
        }
    }

    private static func message(for error: Error) -> String {
        if let migrationError = error as? PaydayMigrationError {
            return migrationError.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "You're offline. Try again when connected."
        }
        return "Sync failed. Try again."
    }
}

enum PaydayDeviceIdentity {
    private static let key = "com.szakacsmedia.payday.supabaseDeviceID"

    static var current: UUID {
        if let rawValue = AppGroup.defaults.string(forKey: key),
           let value = UUID(uuidString: rawValue) {
            return value
        }
        let value = UUID()
        AppGroup.defaults.set(value.uuidString, forKey: key)
        return value
    }
}

struct PaydayCloudGate<Content: View>: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Environment(PolicyStore.self) private var policyStore
    @Environment(OnboardingStateStore.self) private var onboardingStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var cloudState = PaydayCloudState()

    /// Owned by RootView so answers survive the whole signed-out flow.
    let onboardingViewModel: PaydayOnboardingViewModel
    @State private var pendingLocalSync: Task<Void, Never>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch cloudState.phase {
            case .loading:
                CloudProgressView(title: "Opening…")
            case .signedOut:
                // The welcome screen IS the signed-out state. There used to be
                // a separate, plainer PaydaySignInView here, which meant the
                // app had two front doors and signing out landed on the worse
                // one. The flow's own .account stage hosts the Apple button.
                OnboardingFlowView(
                    viewModel: onboardingViewModel,
                    onQuizCompleted: { chosenFrequency in
                        onboardingStore.quizPayFrequency = chosenFrequency
                    },
                    onAuthorize: { result in
                        handleAppleAuthorization(result.authorization, nonce: result.nonce)
                    }
                )
            case .migrating:
                CloudProgressView(title: "Syncing…")
            case .ready:
                // Injected so Settings can offer Sign Out and Delete
                // Account. The gate owns the session, so it is the only
                // thing that can hand out the object that ends one.
                content()
                    .environment(cloudState)
            case .failed(let message):
                CloudMigrationErrorView(
                    message: message,
                    retry: {
                        Task {
                            await cloudState.retryMigration(
                                context: modelContext,
                                scheduleStore: scheduleStore,
                                preferencesStore: preferencesStore,
                                moveLedgerStore: moveLedgerStore,
                                policyStore: policyStore
                            )
                        }
                    },
                    signInAgain: cloudState.showSignIn
                )
            }
        }
        .task {
            #if DEBUG || targetEnvironment(simulator)
            DebugSeeder.seedIfRequested(
                scheduleStore: scheduleStore,
                insightsStore: insightsStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore,
                preferencesStore: preferencesStore
            )
            #endif
            MigrationRunner.runPending(in: modelContext)
            // The two compensation-policy migrations (Design 1). They run
            // AFTER MigrationRunner, so the earliest shift date they read is
            // the repaired one, and BEFORE restore, so a first sync uploads
            // the policies it just created. Neither touches the settings
            // clock, so this cannot make an untouched install look newer
            // than another device's real settings.
            policyStore.runMigrationsIfNeeded(
                resolvedFirstWeekday: scheduleStore.schedule?.resolvedFirstWeekday ?? Calendar.current.firstWeekday,
                earliestShiftDate: PolicyMigrationInputs.earliestShiftDate(in: modelContext),
                baseHourlyWageCents: preferencesStore.baseHourlyWageCents
            )
            await cloudState.restore(
                context: modelContext,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                policyStore: policyStore
            )
        }
        .onChange(of: cloudState.phase) { _, newPhase in
            // The quiz answers exist only to reach a session. Once there is
            // one, drop them, so signing out later reopens a clean welcome
            // rather than one pre-filled from a previous attempt.
            if case .ready = newPhase { onboardingViewModel.reset() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Background launches are precious battery/network time. Local
            // writes remain durable and sync on the next active foreground.
            guard newPhase == .active else { return }
            Task { await syncIfReady() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            queueSyncAfterLocalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: PaydaySettingsSyncClock.didChange)) { _ in
            queueSyncAfterLocalChange()
        }
        .onDisappear {
            pendingLocalSync?.cancel()
            pendingLocalSync = nil
        }
    }

    private func syncIfReady(minimumInterval: TimeInterval? = 120) async {
        guard scenePhase == .active else { return }
        await cloudState.syncIfReady(
            context: modelContext,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore,
            policyStore: policyStore,
            minimumInterval: minimumInterval
        )
    }

    private func queueSyncAfterLocalChange() {
        guard scenePhase == .active, !cloudState.isSynchronizing else { return }
        pendingLocalSync?.cancel()
        pendingLocalSync = Task { @MainActor in
            // Coalesce autosaves and multi-field edits into one network pass.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await syncIfReady(minimumInterval: nil)
        }
    }

    private func handleAppleAuthorization(_ result: Result<ASAuthorization, Error>, nonce: String) {
        do {
            guard let credential = try result.get().credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else {
                return
            }
            Task {
                await cloudState.signInWithApple(
                    idToken: idToken,
                    nonce: nonce,
                    fullName: credential.fullName,
                    context: modelContext,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    policyStore: policyStore
                )
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            cloudState.showSignIn()
        }
    }
}


enum AppleIdentityProfile {
    static func newFirstName(
        from fullName: PersonNameComponents?,
        currentFirstName: String?
    ) -> String? {
        guard currentFirstName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        else { return nil }
        guard let firstName = fullName?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstName.isEmpty
        else { return nil }
        return firstName
    }
}

/// Shared with OnboardingAccountView, which now hosts the button.
enum PaydayAppleNonce {
    private static let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    static func make(length: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in characters.randomElement(using: &generator) })
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CloudProgressView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(title)
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background.ignoresSafeArea())
    }
}

private struct CloudMigrationErrorView: View {
    let message: String
    let retry: () -> Void
    let signInAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Couldn't sync")
                .font(PaydayFont.title)
                .foregroundStyle(PaydayColor.textPrimary)
            Text(message)
                .font(PaydayFont.body)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
            Button("Sign In Again", action: signInAgain)
                .buttonStyle(.plain)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background.ignoresSafeArea())
    }
}
