import SwiftData
import SwiftUI

/// Account deletion, required by App Review Guideline 5.1.1(v).
///
/// A whole sheet rather than a confirmation dialog, and typed confirmation
/// rather than a second tap, because of what this specifically destroys.
/// Payday holds the only complete record many servers have of what they
/// earned: months of shifts, tip-outs, hours, and paychecks. Deleting the
/// account removes the server rows by cascade AND wipes the phone, and
/// nothing anywhere can bring it back.
///
/// So the sheet does three things a dialog cannot. It says exactly what
/// goes, with the real count of shifts at risk rather than a vague "your
/// data". It offers the export first, so the honest alternative to losing
/// the record is one tap away. And it requires the word DELETE typed out,
/// which is the cheapest reliable way to distinguish intent from a
/// mis-tap on a destructive control.
struct DeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Environment(PolicyStore.self) private var policyStore
    @Environment(PaydayCloudState.self) private var cloudState
    @Query private var allEntries: [TipEntry]
    /// The other representation. `shiftCount` picks one -- see the note
    /// there on why this screen in particular cannot be allowed to read the
    /// legacy side alone.
    @Query private var shiftRecords: [ShiftRecord]
    @Query private var paycheckRecords: [PaycheckRecord]

    @State private var typed = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private static let requiredPhrase = "DELETE"

    /// The count of LOGICAL shifts about to be destroyed, from whichever
    /// representation is authoritative.
    ///
    /// Switched rather than legacy-only, and not a sum of the two, for two
    /// separate reasons. Legacy-only would UNDER-report on a converted
    /// account: the user types DELETE having been shown fewer shifts than
    /// deletion actually destroys, which makes this a consent defect on an
    /// irreversible action rather than a display bug. A sum would OVER-report,
    /// because on a converted account the `ShiftRecord`s are derived from the
    /// `TipEntry` rows still sitting beside them, so both representations
    /// describe the same nights and adding them double-counts every one.
    ///
    /// Deletion does wipe both; the honest number is how many shifts the
    /// person loses, which is the authoritative representation's count.
    private var shiftCount: Int {
        if PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount {
            return shiftRecords.count
        }
        return ShiftDays.groupedByShift(allEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod).count
    }

    private var canDelete: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == Self.requiredPhrase && !isDeleting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PaydaySpacing.p20) {
                    Text("This deletes your account and everything in it.")
                        .font(PaydayFont.title3)
                        .foregroundStyle(PaydayColor.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        // The real numbers, not "your data". Someone about to
                        // lose eleven months of records should see that.
                        bullet("\(shiftCount) logged \(shiftCount == 1 ? "shift" : "shifts") on this phone")
                        if !paycheckRecords.isEmpty {
                            bullet("\(paycheckRecords.count) \(paycheckRecords.count == 1 ? "paycheck" : "paychecks")")
                        }
                        bullet("Your pay schedule, hourly wage, and name")
                        bullet("Everything synced to your account")
                    }

                    Text("It cannot be undone, and Payday cannot recover it for you.")
                        .font(PaydayFont.bodyRegular)
                        .foregroundStyle(PaydayColor.textPrimary)

                    // Offered before the destructive control, not after, so
                    // the alternative is visible while the decision is still
                    // being made. Same CSVExport transferable History uses,
                    // so the file is only built when the share sheet asks
                    // for its data.
                    ShareLink(
                        item: CSVExport {
                            CSVExporter.export(
                                entries: allEntries,
                                records: shiftRecords,
                                paycheckRecords: paycheckRecords,
                                calculator: PayPeriodCalculator(payrollTimeZone: policyStore.payrollTimeZone, schedule: scheduleStore.schedule ?? .fallback)
                            )
                        },
                        preview: SharePreview("Payday-Export.csv")
                    ) {
                        Text("Export my shifts first")
                            .font(PaydayFont.bodyRegular)
                            .foregroundStyle(PaydayColor.primary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type DELETE to confirm")
                            .font(PaydayFont.subheadline)
                            .foregroundStyle(PaydayColor.textSecondary)
                        TextField("DELETE", text: $typed)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(PaydayFont.body)
                            .padding(PaydaySpacing.p12)
                            .background(PaydayColor.fieldBackground, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.error)
                    }

                    Button {
                        Task { await performDelete() }
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting { ProgressView().tint(.white) }
                            Text(isDeleting ? "Deleting…" : "Delete Account")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PaydaySpacing.p12)
                    }
                    .background(canDelete ? PaydayColor.error : PaydayColor.error.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .disabled(!canDelete)
                }
                .padding(PaydaySpacing.p16)
            }
            .background(PaydayColor.background)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Cancel, not Done: nothing has been committed, and
                    // Done on a destructive sheet reads like consent.
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(PaydayColor.textSecondary)
            Text(text)
                .font(PaydayFont.bodyRegular)
                .foregroundStyle(PaydayColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func performDelete() async {
        isDeleting = true
        errorMessage = nil
        let failure = await cloudState.deleteAccount(
            context: modelContext,
            scheduleStore: scheduleStore,
            insightsStore: insightsStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore,
            policyStore: policyStore
        )
        isDeleting = false
        if let failure {
            // Nothing was deleted — deleteAccount stops at the server call
            // and leaves local data intact — so the sheet stays open with
            // the reason rather than dismissing into an ambiguous state.
            errorMessage = failure
            return
        }
        // On success the gate has already flipped to .signedOut, which
        // replaces this whole view hierarchy.
        dismiss()
    }
}
