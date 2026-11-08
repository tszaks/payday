import PaydayCore
import SwiftData
import SwiftUI

/// Settings > Connect payroll. Sign in to a payroll account through Truv
/// Bridge, preview the pay stubs, import them as paychecks, and manage the
/// connection afterwards.
struct PayrollConnectionView: View {
    @Environment(PaydayCloudState.self) private var cloudState
    @Environment(PolicyStore.self) private var policyStore
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.modelContext) private var modelContext

    @State private var connection = PayrollConnection.shared
    @State private var bridge: BridgeSession?
    @State private var isConfirmingRemove = false
    @State private var disconnecting: PayrollLink?

    static let explanation = "Sign in to Toast or your payroll provider. Payday reads your pay stubs; it can't change anything."

    private struct BridgeSession: Identifiable {
        let token: String
        var id: String { token }
    }

    private var scope: PayrollImportScope {
        PayrollImportScope(policyStore: policyStore, scheduleStore: scheduleStore)
    }

    var body: some View {
        Form {
            if connection.environment == .sandbox {
                Section {
                    Text("Test mode: sample payroll data")
                        .font(PaydayFont.subheadlineSemibold)
                        .foregroundStyle(PaydayColor.caution)
                }
                .listRowBackground(PaydayColor.fieldBackground)
            }

            if let preview = connection.preview {
                previewSection(preview)
            }

            if connection.isConnected {
                connectedSection
            } else {
                connectSection
            }

            if Self.showsManageSection(links: connection.allLinks, createdCount: connection.ledger.createdCount) {
                manageSection
            }

            if !connection.importedStubs.isEmpty {
                stubsSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(PaydayColor.background)
        .navigationTitle("Payroll")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(connection.isWorking)
        .overlay {
            if connection.isWorking { ProgressView() }
        }
        .task {
            guard cloudState.canReachServer else { return }
            connection.message = nil
            connection.prepare(userID: PaydaySyncState.registeredUserID)
            await connection.refreshStatus()
        }
        .fullScreenCover(item: $bridge) { session in
            TruvBridgeView(
                token: session.token,
                onSuccess: { publicToken in
                    bridge = nil
                    Task { await connection.finishConnect(publicToken: publicToken, context: modelContext, scope: scope) }
                },
                onClose: { bridge = nil }
            )
            .ignoresSafeArea()
        }
        .confirmationDialog(
            "Remove imported paychecks?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                connection.removeImported(context: modelContext, onWrite: reschedule)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only paychecks Payday imported and you haven't changed. Paychecks you typed or edited stay.")
        }
        .confirmationDialog(
            "Disconnect \(disconnecting?.displayName ?? "payroll")?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible,
            presenting: disconnecting
        ) { link in
            Button("Disconnect", role: .destructive) {
                Task { await connection.disconnect(link: link) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Payday stops reading pay stubs. Imported paychecks stay.")
        }
    }

    // MARK: - Sections

    private var connectSection: some View {
        Section {
            waitingLinkRows
            if !connection.isUnavailable {
                Button("Connect payroll") { startConnect() }
                    .disabled(!cloudState.canReachServer)
            }
        } footer: {
            VStack(alignment: .leading, spacing: PaydaySpacing.p8) {
                if !connection.isUnavailable {
                    Text(cloudState.canReachServer ? Self.explanation : "Connect payroll needs an internet connection and a signed-in account.")
                }
                if let message = connection.message { Text(message) }
            }
        }
        .listRowBackground(PaydayColor.fieldBackground)
    }

    /// Links that are not ready: still connecting, or needing a new sign-in
    /// (a changed password, an expired session). Reconnect opens Bridge on
    /// the same link, so no second connection is made.
    @ViewBuilder
    private var waitingLinkRows: some View {
        ForEach(connection.waitingLinks) { link in
            LabeledContent(link.displayName) {
                Text(link.needsSignIn ? "Sign in again" : "Still connecting")
                    .foregroundStyle(link.needsSignIn ? PaydayColor.caution : PaydayColor.textSecondary)
            }
            if link.needsSignIn, !connection.isUnavailable {
                Button(connection.waitingLinks.count > 1 ? "Reconnect \(link.displayName)" : "Reconnect") {
                    startConnect(reconnecting: link)
                }
                .disabled(!cloudState.canReachServer)
            }
        }
        if connection.waitingLinks.contains(where: { !$0.needsSignIn }) {
            Button("Check again") {
                Task { await connection.refreshStatus() }
            }
        }
    }

    private var connectedSection: some View {
        Section {
            ForEach(connection.connectedLinks) { link in
                HStack {
                    Text(link.displayName)
                        .foregroundStyle(PaydayColor.textPrimary)
                    Spacer()
                    if link.employerName != nil, let provider = link.providerName {
                        Text(provider)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
            }
            LabeledContent("Last synced") {
                Text(connection.ledger.lastSyncedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
            }
            LabeledContent("Imported") {
                Text(connection.ledger.createdCount == 1 ? "1 paycheck" : "\(connection.ledger.createdCount) paychecks")
                    .monospacedDigit()
            }
            ForEach(connection.connectedLinks) { link in
                Button(connection.connectedLinks.count > 1 ? "Check \(link.displayName) for new paystubs" : "Check for new paystubs") {
                    Task { await connection.requestRefresh(link: link) }
                }
            }
            if connection.ledger.importConfirmed == false, connection.preview == nil {
                Button("Preview pay stubs") {
                    Task { await connection.loadPreview(context: modelContext, scope: scope) }
                }
            }
            waitingLinkRows
        } header: {
            Text("Connected")
        } footer: {
            if let message = connection.message { Text(message) }
        }
        .listRowBackground(PaydayColor.fieldBackground)
    }

    /// Clean-up, whatever state the links are in: every known link can be
    /// disconnected (ready, syncing or broken), and imported paychecks can
    /// be removed for as long as the import record lists some, connected or
    /// not.
    private var manageSection: some View {
        Section {
            if connection.ledger.createdCount > 0 {
                Button("Remove imported paychecks", role: .destructive) { isConfirmingRemove = true }
            }
            ForEach(connection.allLinks) { link in
                Button(connection.allLinks.count > 1 ? "Disconnect \(link.displayName)" : "Disconnect", role: .destructive) {
                    disconnecting = link
                }
            }
        }
        .listRowBackground(PaydayColor.fieldBackground)
    }

    static func showsManageSection(links: [PayrollLink], createdCount: Int) -> Bool {
        !links.isEmpty || createdCount > 0
    }

    private func previewSection(_ preview: PayrollConnection.Preview) -> some View {
        Section {
            if preview.isEmpty {
                Text("No new pay stubs yet.")
                    .foregroundStyle(PaydayColor.textSecondary)
                if connection.ledger.importConfirmed == false {
                    Button("Import new pay stubs automatically") {
                        connection.confirmImport(context: modelContext, scope: scope, onWrite: reschedule)
                    }
                    .font(PaydayFont.bodySemibold)
                    .tint(PaydayColor.primary)
                }
                Button("Check again") {
                    Task { await connection.loadPreview(context: modelContext, scope: scope) }
                }
            } else {
                Text(Self.previewHeadline(preview))
                    .foregroundStyle(PaydayColor.textPrimary)
                ForEach(preview.rows) { stub in
                    HStack {
                        Text(Self.dayLabel(stub.payDate))
                            .foregroundStyle(PaydayColor.textPrimary)
                        Spacer()
                        if let net = stub.netPayCents {
                            Text(Money.string(fromCents: net))
                                .monospacedDigit()
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("Import") {
                    connection.confirmImport(context: modelContext, scope: scope, onWrite: reschedule)
                    PaydayHaptics.success()
                }
                .font(PaydayFont.bodySemibold)
                .tint(PaydayColor.primary)
            }
        } header: {
            Text("Ready to import")
        } footer: {
            VStack(alignment: .leading, spacing: PaydaySpacing.p8) {
                if preview.paysMoreOftenThanSchedule {
                    Text(Self.scheduleNotice)
                        .foregroundStyle(PaydayColor.caution)
                }
                if preview.isEmpty {
                    Text("Payday checks for new pay stubs when you open it.")
                } else {
                    Text("Pay stubs for periods you already logged fill in only what's missing there.")
                }
            }
        }
        .listRowBackground(PaydayColor.fieldBackground)
    }

    private var stubsSection: some View {
        Section("Pay stubs") {
            ForEach(connection.importedStubs.prefix(12), id: \.sourceID) { stub in
                DisclosureGroup {
                    ForEach(stub.entry.deductions, id: \.self) { line in
                        LabeledContent(line.name) {
                            Text(Money.string(fromCents: line.cents)).monospacedDigit()
                        }
                        .font(PaydayFont.subheadline)
                    }
                    if stub.entry.deductions.isEmpty {
                        Text("No deductions listed.")
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                } label: {
                    HStack {
                        Text(Self.dayLabel(stub.entry.payDate))
                            .foregroundStyle(PaydayColor.textPrimary)
                        Spacer()
                        if let hours = stub.entry.hours {
                            Text("\(hours) h")
                                .monospacedDigit()
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    }
                }
            }
        }
        .listRowBackground(PaydayColor.fieldBackground)
    }

    // MARK: - Actions

    private func startConnect(reconnecting link: PayrollLink? = nil) {
        PaydayHaptics.lightTap()
        connection.message = nil
        Task {
            connection.prepare(userID: PaydaySyncState.registeredUserID)
            if let token = await connection.bridgeToken(reconnecting: link) {
                bridge = BridgeSession(token: token)
            }
        }
    }

    private func reschedule() {
        PayrollConnection.rescheduleReminders(context: modelContext, preferencesStore: preferencesStore, scheduleStore: scheduleStore)
    }

    // MARK: - Copy

    /// "Oct 31, 2026" for an ISO day, read as that civil day (no zone shift).
    static func dayLabel(_ iso: String) -> String {
        guard let day = CivilDay(iso: iso) else { return iso }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.timeZone = .gmt
        return day.date(in: .gmt).formatted(style)
    }

    static let scheduleNotice = "Some of these pay stubs are for the same pay period in Payday: your payroll pays more often than your pay schedule. Each one is its own paycheck. To compare them with your shifts, change your pay schedule in Settings."

    static func previewHeadline(_ preview: PayrollConnection.Preview) -> String {
        var parts: [String] = []
        if preview.newCount > 0 {
            parts.append(preview.newCount == 1 ? "1 new paycheck" : "\(preview.newCount) new paychecks")
        }
        if preview.filledCount > 0 {
            parts.append(preview.filledCount == 1 ? "1 to fill in" : "\(preview.filledCount) to fill in")
        }
        var headline = parts.joined(separator: ", ")
        if let first = preview.firstPayDate, let last = preview.lastPayDate, first != last {
            headline += ", \(dayLabel(first)) – \(dayLabel(last))"
        }
        return headline
    }
}

/// The Settings row that opens the connection screen.
struct PayrollConnectionSettingsSection: View {
    @Environment(PaydayCloudState.self) private var cloudState
    @State private var connection = PayrollConnection.shared

    var body: some View {
        Section {
            NavigationLink {
                PayrollConnectionView()
            } label: {
                HStack {
                    Text(connection.ledger.hasConnection ? "Payroll connection" : "Connect payroll")
                        .foregroundStyle(PaydayColor.textPrimary)
                    Spacer()
                    if connection.ledger.hasConnection {
                        Text("On")
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
            }
            .disabled(!cloudState.canReachServer)
        } footer: {
            Text(cloudState.canReachServer
                ? PayrollConnectionView.explanation
                : "Connect payroll needs an internet connection and a signed-in account.")
        }
        .listRowBackground(PaydayColor.fieldBackground)
        .onAppear { connection.prepare(userID: PaydaySyncState.registeredUserID) }
    }
}
