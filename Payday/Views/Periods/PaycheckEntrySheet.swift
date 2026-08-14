import SwiftUI
import SwiftData
import PhotosUI
import UIKit

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
    // (2026-07-27) means none of these ever read the Settings wage.
    @State private var regularWagesCents: Int = 0
    @State private var overtimeWagesCents: Int = 0
    @State private var grossPayCents: Int = 0
    @State private var taxesCents: Int = 0
    @State private var netPayCents: Int = 0
    @FocusState private var focusedDetailField: PaycheckDetailField?
    @State private var showScanOptions = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoSource: PaycheckPhotoSource?
    @State private var isScanning = false
    @State private var scanStatus: String?
    @State private var scanError: String?

    init(period: PayPeriod, existing: PaycheckRecord?) {
        self.period = period
        self.existing = existing
        _amountCents = State(initialValue: existing?.paidTipsCents ?? 0)
        _note = State(initialValue: existing?.note ?? "")
        _regularWagesCents = State(initialValue: existing?.regularWagesCents ?? 0)
        _overtimeWagesCents = State(initialValue: existing?.overtimeWagesCents ?? 0)
        _grossPayCents = State(initialValue: existing?.grossPayCents ?? 0)
        _taxesCents = State(initialValue: existing?.taxesCents ?? 0)
        _netPayCents = State(initialValue: existing?.netPayCents ?? 0)
    }

    /// Forward-only reading-order chain: Regular wages -> Overtime wages ->
    /// Gross income -> Taxes -> Net income -> nil (Save sits right beside
    /// Next at that point).
    private func nextDetailField(after field: PaycheckDetailField) -> PaycheckDetailField? {
        switch field {
        case .regularWages: return .overtimeWages
        case .overtimeWages: return .grossIncome
        case .grossIncome: return .taxes
        case .taxes: return .netIncome
        case .netIncome: return nil
        }
    }

    /// This period's entries, shared by the wages footnote, the audit's
    /// computed-wages input, and the logged-tips comparison below.
    private var periodEntries: [TipEntry] {
        allEntries.filter { $0.date >= period.start && $0.date <= period.end }
    }

    /// One instruction. It used to say "not the check total" and then, in a
    /// second sentence, "your stub should also show $206.21 in wages for
    /// 72h 52m; don't include that here" — the same "tips only, no wages" rule
    /// stated twice, with a wage figure this sheet does not record.
    private var explainerText: String {
        "Enter the tips line from the pay stub, not the check total."
    }

    /// What the stub's tips line should read — the audit's ground truth for the
    /// tips-vs-logged check, from the one shared formula. Credit tips NET OF
    /// TIP-OUT: this used to compare a real stub against GROSS credit, so every
    /// period with a tip-out was reported as short by exactly the tip-out.
    /// Nil (not zero) when nothing's been logged as credit, same
    /// silence-over-nagging treatment as every other audit input: a period
    /// that's cash-only isn't a discrepancy.
    private var loggedCreditTipsCents: Int? {
        let breakdown = TipBreakdown.total(of: periodEntries)
        guard breakdown.creditCents > 0 else { return nil }
        return PredictedPaycheck.tipsLineCents(from: breakdown)
    }

    /// Base + overtime wages PeriodIncome computes from this period's
    /// punches — the audit's ground truth for the wages-vs-computed and
    /// overtime-missing checks. Nil when no rate is set or no hours were
    /// logged, same as everywhere else PeriodIncome is read.
    private var computedWages: PeriodIncome.Wages? {
        PeriodIncome.wages(entries: periodEntries, wageCentsPerHour: preferencesStore.baseHourlyWageCents, firstWeekday: scheduleStore.schedule?.firstWeekday)
    }

    private var auditStub: PaycheckAudit.Stub {
        PaycheckAudit.Stub(
            tipsCents: amountCents > 0 ? amountCents : nil,
            regularWagesCents: regularWagesCents > 0 ? regularWagesCents : nil,
            overtimeWagesCents: overtimeWagesCents > 0 ? overtimeWagesCents : nil,
            grossCents: grossPayCents > 0 ? grossPayCents : nil,
            taxesCents: taxesCents > 0 ? taxesCents : nil,
            netCents: netPayCents > 0 ? netPayCents : nil
        )
    }

    /// Recomputed on every field change — PaycheckAudit is pure and cheap,
    /// so there's no reason to debounce or cache this.
    private var auditFindings: [PaycheckAudit.Finding] {
        PaycheckAudit.run(stub: auditStub, loggedCreditTipsCents: loggedCreditTipsCents, computedWages: computedWages, computedOvertimeHours: computedWages?.overtimeHours)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("TIPS EARNED")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        CurrencyAmountField(cents: $amountCents)
                        Text(explainerText)
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        scanPaycheckButton
                    }
                    .padding(.top, 8)

                    paycheckDetailsCard

                    if !auditFindings.isEmpty {
                        checksSection
                    }

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
                // internally) — this Next chain covers only the five detail
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
        .confirmationDialog("Scan pay stub", isPresented: $showScanOptions, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") {
                    photoSource = .camera
                }
            }
            Button("Choose from Photos", systemImage: "photo") {
                showPhotoPicker = true
            }
        } message: {
            Text("Payday will read the amounts on the image and fill the form for you.")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .sheet(item: $photoSource) { source in
            PaycheckImagePicker(sourceType: source.sourceType) { image in
                Task { await scan(image: image) }
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await scan(photoItem: item) }
        }
        .alert("Pay stub scan", isPresented: Binding(
            get: { scanError != nil },
            set: { if !$0 { scanError = nil } }
        )) {
            Button("OK") { scanError = nil }
        } message: {
            Text(scanError ?? "")
        }
    }

    private var scanPaycheckButton: some View {
        VStack(spacing: 8) {
            Button {
                showScanOptions = true
            } label: {
                Label("Scan pay stub", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(isScanning)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading your pay stub on this device…")
                }
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
            } else if let scanStatus {
                Text(scanStatus)
                    .font(PaydayFont.footnote)
                    .foregroundStyle(PaydayColor.primary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }

    // MARK: Stub details — capture-only, below the tips verification anchor

    /// The stub's other printed facts, in the order Tyler reads a stub:
    /// Regular -> Overtime -> Gross -> Taxes -> Net. Same recessed-fill,
    /// divider-separated grammar as LogTipSheet's shiftDetailsCard. Every
    /// row is optional; leaving all five at zero saves exactly what this
    /// sheet always saved before this existed.
    private var paycheckDetailsCard: some View {
        VStack(spacing: 0) {
            paycheckDetailRow(label: "Regular Wages", cents: $regularWagesCents, field: .regularWages, caption: "Base pay for the period.")
            Divider()
            paycheckDetailRow(label: "Overtime Wages", cents: $overtimeWagesCents, field: .overtimeWages)
            Divider()
            paycheckDetailRow(label: "Gross Income", cents: $grossPayCents, field: .grossIncome, caption: "Before taxes and deductions.")
            Divider()
            paycheckDetailRow(label: "Taxes", cents: $taxesCents, field: .taxes)
            Divider()
            paycheckDetailRow(label: "Net Income", cents: $netPayCents, field: .netIncome, caption: "The amount on the paycheck.")
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

    /// Flat list of what the audit found — no card, matching the sheet's
    /// existing no-cards-beyond-the-fields-card grammar. Reconciling checks
    /// read the quietest, discrepancies the loudest.
    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHECKS")
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)
            ForEach(auditFindings) { finding in
                Text(finding.message)
                    .font(PaydayFont.caption)
                    .foregroundStyle(color(for: finding.severity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func color(for severity: PaycheckAudit.Severity) -> Color {
        switch severity {
        case .reconciles: PaydayColor.textTertiary
        case .note: PaydayColor.textSecondary
        case .discrepancy: PaydayColor.error
        }
    }

    @MainActor
    private func scan(photoItem: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                throw PaycheckOCR.ScanError.imageUnavailable
            }
            await scan(image: image)
        } catch {
            scanError = error.localizedDescription
        }
    }

    @MainActor
    private func scan(image: UIImage) async {
        isScanning = true
        scanStatus = nil
        defer { isScanning = false }

        do {
            let parsed = try await PaycheckOCR.parse(image: image)
            if let tipsCents = parsed.tipsCents { amountCents = tipsCents }
            if let regularWagesCents = parsed.regularWagesCents { self.regularWagesCents = regularWagesCents }
            if let overtimeWagesCents = parsed.overtimeWagesCents { self.overtimeWagesCents = overtimeWagesCents }
            if let grossPayCents = parsed.grossPayCents { self.grossPayCents = grossPayCents }
            if let taxesCents = parsed.taxesCents { self.taxesCents = taxesCents }
            if let netPayCents = parsed.netPayCents { self.netPayCents = netPayCents }

            if parsed.filledFieldCount == 6 {
                scanStatus = "All six fields filled. Review the numbers before saving."
            } else {
                let fieldWord = parsed.filledFieldCount == 1 ? "field" : "fields"
                scanStatus = "Filled " + String(parsed.filledFieldCount) + " " + fieldWord + ". Review the remaining fields before saving."
            }
            PaydayHaptics.success()
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func save() {
        let effectiveRegularWagesCents = regularWagesCents > 0 ? regularWagesCents : nil
        let effectiveOvertimeWagesCents = overtimeWagesCents > 0 ? overtimeWagesCents : nil
        let effectiveGrossPayCents = grossPayCents > 0 ? grossPayCents : nil
        let effectiveTaxesCents = taxesCents > 0 ? taxesCents : nil
        let effectiveNetPayCents = netPayCents > 0 ? netPayCents : nil

        let record: PaycheckRecord
        if let existing {
            existing.paidTipsCents = amountCents
            existing.note = note.isEmpty ? nil : note
            existing.regularWagesCents = effectiveRegularWagesCents
            existing.overtimeWagesCents = effectiveOvertimeWagesCents
            existing.grossPayCents = effectiveGrossPayCents
            existing.taxesCents = effectiveTaxesCents
            existing.netPayCents = effectiveNetPayCents
            record = existing
        } else {
            record = PaycheckRecord(
                periodStart: period.start,
                periodEnd: period.end,
                paidTipsCents: amountCents,
                note: note.isEmpty ? nil : note,
                grossPayCents: effectiveGrossPayCents,
                netPayCents: effectiveNetPayCents,
                regularWagesCents: effectiveRegularWagesCents,
                overtimeWagesCents: effectiveOvertimeWagesCents,
                taxesCents: effectiveTaxesCents
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
    case regularWages
    case overtimeWages
    case grossIncome
    case taxes
    case netIncome
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

private enum PaycheckPhotoSource: String, Identifiable {
    case camera

    var id: String { rawValue }

    var sourceType: UIImagePickerController.SourceType {
        switch self {
        case .camera: .camera
        }
    }
}

private struct PaycheckImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        picker.sourceType = sourceType
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
