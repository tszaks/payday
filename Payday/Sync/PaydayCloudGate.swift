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
        moveLedgerStore: MoveLedgerStore
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
        let userID: UUID
        do {
            userID = try await client.auth.session.user.id
        } catch {
            // A verified account remains usable from its local cache even if
            // the JWT needs a network refresh. The periodic sync below will
            // retry quietly when connectivity returns.
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
                showProgress: false
            )
        } else {
            await migrate(
                context: context,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore
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
        moveLedgerStore: MoveLedgerStore
    ) async {
        phase = .migrating
        do {
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
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
                    showProgress: false
                )
            } else {
                await migrate(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore
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
        moveLedgerStore: MoveLedgerStore
    ) async {
        do {
            let userID = try await client.auth.session.user.id
            if PaydaySyncState.migrationIsVerified(for: userID) {
                await synchronize(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore,
                    showProgress: true
                )
            } else {
                await migrate(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore
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
        moveLedgerStore: MoveLedgerStore
    ) async -> String? {
        do {
            try await client.rpc("delete_my_account").execute()
        } catch {
            Self.logger.error("Account deletion failed: \(String(describing: error), privacy: .public)")
            return Self.message(for: error)
        }

        PaydayAccountEraser.eraseLocalData(
            context: context,
            scheduleStore: scheduleStore,
            insightsStore: insightsStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore
        )

        // The account is already gone, so a failure here is cosmetic: there
        // is no session left to revoke server-side.
        try? await client.auth.signOut()
        phase = .signedOut
        return nil
    }

    func showSignIn() {
        phase = .signedOut
    }

    private func migrate(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore
    ) async {
        phase = .migrating
        do {
            phase = .ready(try await migrationService.migrate(
                context: context,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
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
                moveLedgerStore: moveLedgerStore
            )
            while outcome.requiresFollowUpSync {
                outcome = try await syncService.synchronize(
                    context: context,
                    scheduleStore: scheduleStore,
                    preferencesStore: preferencesStore,
                    moveLedgerStore: moveLedgerStore
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var cloudState = PaydayCloudState()
    @State private var pendingLocalSync: Task<Void, Never>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch cloudState.phase {
            case .loading:
                CloudProgressView(title: "Opening…")
            case .signedOut:
                PaydaySignInView { result in
                    handleAppleAuthorization(result.authorization, nonce: result.nonce)
                }
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
                                moveLedgerStore: moveLedgerStore
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
                preferencesStore: preferencesStore
            )
            #endif
            MigrationRunner.runPending(in: modelContext)
            await cloudState.restore(
                context: modelContext,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore
            )
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
                    moveLedgerStore: moveLedgerStore
                )
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            cloudState.showSignIn()
        }
    }
}

private struct PaydaySignInView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = PaydayAppleNonce.make()
    let completion: ((authorization: Result<ASAuthorization, Error>, nonce: String)) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Sign in to Payday")
                    .font(PaydayFont.title)
                    .foregroundStyle(PaydayColor.textPrimary)
                Text("Sync across devices.")
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            SignInWithAppleButton(.continue) { request in
                nonce = PaydayAppleNonce.make()
                request.requestedScopes = [.email, .fullName]
                request.nonce = PaydayAppleNonce.sha256(nonce)
            } onCompletion: { result in
                completion((result, nonce))
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            Spacer()
        }
        .padding(28)
        .background(PaydayColor.background.ignoresSafeArea())
    }
}

private enum PaydayAppleNonce {
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
