import SwiftUI
import SwiftData

struct PaycheckEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    let period: PayPeriod
    let existing: PaycheckRecord?

    @State private var amountCents: Int
    @State private var note: String
    @State private var showDeleteConfirmation = false

    // Capture-only stub facts, below the tips verification anchor — same
    // zero-means-nil treatment as LogTipSheet's tip-out/sales: stored as a
    // plain Int here, only collapsed to nil at save time (see
    // effectiveDetailCents). No prefills, ever: Tyler's no-assumptions law
    // (2026-07-27) means even hourlyRateCents never reads the Settings wage.
    @State private var hourlyRateCents: Int = 0
    @State private var grossPayCents: Int = 0
    @State private var netPayCents: Int = 0
    @State private var tipsOwedCents: Int = 0
    @FocusState private var focusedDetailField: PaycheckDetailField?

    init(period: PayPeriod, existing: PaycheckRecord?) {
        self.period = period
        self.existing = existing
        _amountCents = State(initialValue: existing?.paidTipsCents ?? 0)
        _note = State(initialValue: existing?.note ?? "")
        _hourlyRateCents = State(initialValue: existing?.hourlyRateCents ?? 0)
        _grossPayCents = State(initialValue: existing?.grossPayCents ?? 0)
        _netPayCents = State(initialValue: existing?.netPayCents ?? 0)
        _tipsOwedCents = State(initialValue: existing?.owedTipsCents ?? 0)
    }

    /// Forward-only reading-order chain: Hourly rate -> Gross pay -> Net pay
    /// -> Tips owed -> nil (Save sits right beside Next at that point).
    private func nextDetailField(after field: PaycheckDetailField) -> PaycheckDetailField? {
        switch field {
        case .hourlyRate: return .grossPay
        case .grossPay: return .netPay
        case .netPay: return .tipsOwed
        case .tipsOwed: return nil
        }
    }

    /// Hours logged for this period, for the wages footnote only — never fed
    /// into the tips amount this sheet records.
    private var loggedHours: Double {
        let periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        let shiftGroups = ShiftDays.groupedByShift(periodEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod).map(\.items)
        return WageEstimate.loggedHours(shiftGroups: shiftGroups)
    }

    private var explainerText: String {
        let base = "Enter the tips amount from the pay stub — not the check total."
        guard let wageEstimateCents = WageEstimate.cents(wageCentsPerHour: preferencesStore.baseHourlyWageCents, hours: loggedHours) else {
            return base
        }
        let wages = Money.string(fromCents: wageEstimateCents)
        let hours = WageEstimate.hoursLabel(loggedHours)
        return "\(base) Your stub should also show \(wages) in wages for \(hours); don't include that here."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text(explainerText)
                        .font(PaydayFont.footnote)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    CurrencyAmountField(cents: $amountCents)
                        .padding(.top, 8)

                    paycheckDetailsCard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Note")
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                        TextField("Optional", text: $note, axis: .vertical)
                            .lineLimit(2...6)
                    }
                    .padding()
                    .background(PaydayColor.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg))
                    .padding(.horizontal)

                    if existing != nil {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Text("Remove Paycheck")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PaydayColor.error)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .confirmationDialog("Remove this paycheck?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                            Button("Remove Paycheck", role: .destructive) { delete() }
                        }
                    }

                    Spacer()
                }
                .padding(.top, 16)
            }
            .background(PaydayColor.background)
            .navigationTitle("Paycheck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(amountCents == 0)
                }
                // The tips field above autofocuses on its own and has no
                // external FocusState (CurrencyAmountField owns it
                // internally) — this Next chain covers only the four detail
                // fields below it, in reading order.
                if let focusedDetailField {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        if let next = nextDetailField(after: focusedDetailField) {
                            Button("Next") {
                                PaydayHaptics.selection()
                                self.focusedDetailField = next
                            }
                        }
                        Button("Save") { save() }
                            .buttonStyle(.glassProminent)
                            .disabled(amountCents == 0)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(PaydayColor.background)
    }

    // MARK: Stub details — capture-only, below the tips verification anchor

    /// The stub's other printed facts — same recessed-fill, divider-
    /// separated grammar as LogTipSheet's shiftDetailsCard. Every row is
    /// optional; leaving all four at zero saves exactly what this sheet
    /// always saved before this existed.
    private var paycheckDetailsCard: some View {
        VStack(spacing: 0) {
            paycheckDetailRow(label: "Hourly rate", cents: $hourlyRateCents, field: .hourlyRate, caption: "The rate printed on the stub.")
            Divider()
            paycheckDetailRow(label: "Gross pay", cents: $grossPayCents, field: .grossPay)
            Divider()
            paycheckDetailRow(label: "Net pay", cents: $netPayCents, field: .netPay)
            Divider()
            paycheckDetailRow(label: "Tips owed", cents: $tipsOwedCents, field: .tipsOwed, caption: "Tips this check still owes you.")
        }
        .padding()
        .background(PaydayColor.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func paycheckDetailRow(label: String, cents: Binding<Int>, field: PaycheckDetailField, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                Spacer()
                PaycheckCurrencyField(cents: cents, field: field, focusedField: $focusedDetailField)
            }
            if let caption {
                Text(caption)
                    .font(PaydayFont.footnote)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .padding(.vertical, 14)
    }

    private func save() {
        let effectiveHourlyRateCents = hourlyRateCents > 0 ? hourlyRateCents : nil
        let effectiveGrossPayCents = grossPayCents > 0 ? grossPayCents : nil
        let effectiveNetPayCents = netPayCents > 0 ? netPayCents : nil
        let effectiveTipsOwedCents = tipsOwedCents > 0 ? tipsOwedCents : nil

        let record: PaycheckRecord
        if let existing {
            existing.paidTipsCents = amountCents
            existing.note = note.isEmpty ? nil : note
            existing.hourlyRateCents = effectiveHourlyRateCents
            existing.grossPayCents = effectiveGrossPayCents
            existing.netPayCents = effectiveNetPayCents
            existing.owedTipsCents = effectiveTipsOwedCents
            record = existing
        } else {
            record = PaycheckRecord(
                periodStart: period.start,
                periodEnd: period.end,
                paidTipsCents: amountCents,
                note: note.isEmpty ? nil : note,
                hourlyRateCents: effectiveHourlyRateCents,
                owedTipsCents: effectiveTipsOwedCents,
                grossPayCents: effectiveGrossPayCents,
                netPayCents: effectiveNetPayCents
            )
            modelContext.insert(record)
        }
        PaydayHaptics.success()
        PaydayWidgetRefresh.request()
        // A recorded paycheck means this period's verification is done —
        // reschedule so a pending payday push for it clears immediately
        // instead of surviving until the next unrelated reschedule call.
        let updatedRecords = paycheckRecords.contains(where: { $0.id == record.id }) ? paycheckRecords : paycheckRecords + [record]
        PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries, paycheckRecords: updatedRecords)
        dismiss()
    }

    private func delete() {
        if let existing {
            modelContext.delete(existing)
        }
        PaydayWidgetRefresh.request()
        dismiss()
    }
}

/// Which stub-detail field the keypad is driving — owned by the sheet so a
/// keyboard toolbar "Next" button can move focus in reading order. Scoped to
/// this sheet alone, same pattern as LogTipSheet's CurrencyRowField but for
/// a different field set.
private enum PaycheckDetailField: Hashable {
    case hourlyRate
    case grossPay
    case netPay
    case tipsOwed
}

/// Same digit-shift-from-the-right technique and focus-ring treatment as
/// LogTipSheet's CompactCurrencyField, scoped to this sheet's own field set
/// and focus chain.
private struct PaycheckCurrencyField: View {
    @Binding var cents: Int
    let field: PaycheckDetailField
    var focusedField: FocusState<PaycheckDetailField?>.Binding
    @State private var digitsText: String = ""

    private static let maxDigits = 7
    private var isFocused: Bool { focusedField.wrappedValue == field }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(Money.string(fromCents: cents))
                .font(PaydayFont.body)
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
            TextField("", text: $digitsText)
                .keyboardType(.numberPad)
                .focused(focusedField, equals: field)
                .opacity(0.01)
                .multilineTextAlignment(.trailing)
                .accessibilityValue(Money.string(fromCents: cents))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 92, alignment: .trailing)
        .overlay(
            RoundedRectangle(cornerRadius: PaydayRadius.sm)
                .strokeBorder(isFocused ? PaydayColor.primary : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedField.wrappedValue = field }
        .onAppear {
            digitsText = cents == 0 ? "" : String(cents)
        }
        .onChange(of: digitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxDigits))
            if filtered != newValue { digitsText = filtered }
            cents = Int(filtered) ?? 0
        }
    }
}
