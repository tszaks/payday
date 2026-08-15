import SwiftUI
import SwiftData
import PhotosUI
import OSLog
import UIKit

struct PaycheckEntrySheet: View {
    private enum PaycheckScannedField: Hashable {
        case tips
        case regularWages
        case overtimeWages
        case gratuity
        case grossPay
        case taxes
        case netPay
    }

    private struct PaycheckScanSnapshot {
        let touched: Set<PaycheckScannedField>
        let amountCents: Int
        let regularWagesCents: Int
        let overtimeWagesCents: Int
        let gratuityCents: Int
        let grossPayCents: Int
        let taxesCents: Int
        let netPayCents: Int
    }

    private static let scanLogger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "PaycheckScanUI"
    )

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var gratuityCents: Int = 0
    @State private var grossPayCents: Int = 0
    @State private var taxesCents: Int = 0
    @State private var netPayCents: Int = 0
    @FocusState private var focusedDetailField: PaycheckDetailField?
    @State private var showScanOptions = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoSource: PaycheckPhotoSource?
    @State private var isScanning = false
    @State private var scanSlotState: ScanInputSlotState = .rest
    @State private var scanSnapshot: PaycheckScanSnapshot?
    @State private var scanResetTask: Task<Void, Never>?

    init(period: PayPeriod, existing: PaycheckRecord?) {
        self.period = period
        self.existing = existing
        _amountCents = State(initialValue: existing?.paidTipsCents ?? 0)
        _note = State(initialValue: existing?.note ?? "")
        _regularWagesCents = State(initialValue: existing?.regularWagesCents ?? 0)
        _overtimeWagesCents = State(initialValue: existing?.overtimeWagesCents ?? 0)
        _gratuityCents = State(initialValue: existing?.gratuityCents ?? 0)
        _grossPayCents = State(initialValue: existing?.grossPayCents ?? 0)
        _taxesCents = State(initialValue: existing?.taxesCents ?? 0)
        _netPayCents = State(initialValue: existing?.netPayCents ?? 0)
    }

    /// Forward-only reading-order chain: Regular wages -> Overtime wages ->
    /// Gratuity -> Gross income -> Taxes -> Net income -> nil.
    private func nextDetailField(after field: PaycheckDetailField) -> PaycheckDetailField? {
        switch field {
        case .regularWages: return .overtimeWages
        case .overtimeWages: return .gratuity
        case .gratuity: return .grossIncome
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
            gratuityCents: gratuityCents > 0 ? gratuityCents : nil,
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
                        scanPaycheckSlot
                        Text(explainerText)
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
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
                // internally) — this Next chain covers only the six detail
                // fields below it, in reading order.
                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: presentPaycheckScanOptions) {
                        ScanInputLabel(title: "Scan pay stub")
                    }
                    Spacer()
                    if let focusedDetailField {
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
            if PaydayCameraView.isCameraAvailable {
                Button("Take Photo", systemImage: "camera") {
                    photoSource = .camera
                }
            }
            Button("Choose from Photos", systemImage: "photo") {
                showPhotoPicker = true
            }
        } message: {
            if PaycheckAIParser.isConfigured {
                Text("Payday will send the photo to OpenAI to read and combine the pay-period totals, then fill the form for you.")
            } else {
                Text("Payday will read the amounts on the image on this device and fill the form for you.")
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .sheet(item: $photoSource) { source in
            PaydayCameraView(title: "Scan pay stub") { image in
                Task { await scan(image: image) }
            }
            .ignoresSafeArea()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await scan(photoItem: item) }
        }
        .onDisappear { scanResetTask?.cancel() }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-DebugScanSlot"), args.count > index + 1 {
                switch args[index + 1] {
                case "analyzing": scanSlotState = .analyzing
                case "scanned": scanSlotState = .scanned
                case "error": scanSlotState = .error("Couldn’t analyze pay stub.")
                default: scanSlotState = .rest
                }
            }
        }
        #endif
    }

    private var scanPaycheckSlot: some View {
        ScanInputSlot(
            title: "Scan pay stub",
            state: scanSlotState,
            onScan: presentPaycheckScanOptions,
            onUndo: undoPaycheckScan
        )
        .padding(.horizontal)
    }

    // MARK: Stub details — capture-only, below the tips verification anchor

    /// The stub's other printed facts, in the order Tyler reads a stub:
    /// Regular -> Overtime -> Gratuity -> Gross -> Taxes -> Net. Same recessed-fill,
    /// divider-separated grammar as LogTipSheet's shiftDetailsCard. Every
    /// row is optional; leaving all six at zero saves exactly what this
    /// sheet always saved before this existed.
    private var paycheckDetailsCard: some View {
        VStack(spacing: 0) {
            paycheckDetailRow(label: "Regular Wages", cents: $regularWagesCents, field: .regularWages, caption: "Base pay for the period.")
            Divider()
            paycheckDetailRow(label: "Overtime Wages", cents: $overtimeWagesCents, field: .overtimeWages)
            Divider()
            paycheckDetailRow(label: "Gratuity", cents: $gratuityCents, field: .gratuity)
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
    private func presentPaycheckScanOptions() {
        guard !isScanning else { return }
        scanResetTask?.cancel()
        scanSnapshot = nil
        setPaycheckScanSlotState(.rest)
        focusedDetailField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        Task { @MainActor in
            await Task.yield()
            showScanOptions = true
        }
    }

    @MainActor
    private func setPaycheckScanSlotState(_ state: ScanInputSlotState, resetAfter seconds: Int? = nil) {
        scanResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            scanSlotState = state
        }

        guard let seconds else { return }
        scanResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                scanSlotState = .rest
            }
            scanSnapshot = nil
        }
    }

    @MainActor
    private func undoPaycheckScan() {
        guard let snapshot = scanSnapshot else {
            setPaycheckScanSlotState(.rest)
            return
        }

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            if snapshot.touched.contains(.tips) { amountCents = snapshot.amountCents }
            if snapshot.touched.contains(.regularWages) { regularWagesCents = snapshot.regularWagesCents }
            if snapshot.touched.contains(.overtimeWages) { overtimeWagesCents = snapshot.overtimeWagesCents }
            if snapshot.touched.contains(.gratuity) { gratuityCents = snapshot.gratuityCents }
            if snapshot.touched.contains(.grossPay) { grossPayCents = snapshot.grossPayCents }
            if snapshot.touched.contains(.taxes) { taxesCents = snapshot.taxesCents }
            if snapshot.touched.contains(.netPay) { netPayCents = snapshot.netPayCents }
        }
        scanSnapshot = nil
        setPaycheckScanSlotState(.rest)
        PaydayHaptics.selection()
    }

    @MainActor
    private func scan(photoItem: PhotosPickerItem) async {
        guard !isScanning else {
            Self.scanLogger.notice("Paycheck photo-library import ignored because a scan is already active")
            selectedPhotoItem = nil
            return
        }
        let importStartedAt = Date()
        Self.scanLogger.notice("Paycheck photo-library import started")
        isScanning = true
        scanSnapshot = nil
        setPaycheckScanSlotState(.analyzing)
        defer {
            isScanning = false
            selectedPhotoItem = nil
        }
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                throw PaycheckOCR.ScanError.imageUnavailable
            }
            let importMilliseconds = Int(Date().timeIntervalSince(importStartedAt) * 1_000)
            Self.scanLogger.notice(
                "Paycheck photo-library import completed. bytes=\(data.count) elapsedMs=\(importMilliseconds)"
            )
            await scan(image: image)
        } catch {
            let errorType = String(describing: type(of: error))
            Self.scanLogger.error(
                "Paycheck photo-library import failed. type=\(errorType, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
            )
            scanSnapshot = nil
            setPaycheckScanSlotState(.error(error.localizedDescription), resetAfter: 4)
        }
    }

    @MainActor
    private func scan(image: UIImage) async {
        let scanStartedAt = Date()
        Self.scanLogger.notice(
            "Paycheck scan UI started. pixels=\(Int(image.size.width))x\(Int(image.size.height))"
        )
        isScanning = true
        scanSnapshot = nil
        setPaycheckScanSlotState(.analyzing)
        defer {
            isScanning = false
            let elapsedMilliseconds = Int(Date().timeIntervalSince(scanStartedAt) * 1_000)
            Self.scanLogger.notice(
                "Paycheck scan UI ended. elapsedMs=\(elapsedMilliseconds)"
            )
        }

        do {
            let parsed = try await PaycheckOCR.parse(image: image)
            let snapshotAmountCents = amountCents
            let snapshotRegularWagesCents = regularWagesCents
            let snapshotOvertimeWagesCents = overtimeWagesCents
            let snapshotGratuityCents = gratuityCents
            let snapshotGrossPayCents = grossPayCents
            let snapshotTaxesCents = taxesCents
            let snapshotNetPayCents = netPayCents
            var touched: Set<PaycheckScannedField> = []

            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                if let tipsCents = parsed.tipsCents {
                    touched.insert(.tips)
                    amountCents = tipsCents
                }
                if let parsedRegularWagesCents = parsed.regularWagesCents {
                    touched.insert(.regularWages)
                    regularWagesCents = parsedRegularWagesCents
                }
                if let parsedOvertimeWagesCents = parsed.overtimeWagesCents {
                    touched.insert(.overtimeWages)
                    overtimeWagesCents = parsedOvertimeWagesCents
                }
                if let parsedGratuityCents = parsed.gratuityCents {
                    touched.insert(.gratuity)
                    gratuityCents = parsedGratuityCents
                }
                if let parsedGrossPayCents = parsed.grossPayCents {
                    touched.insert(.grossPay)
                    grossPayCents = parsedGrossPayCents
                }
                if let parsedTaxesCents = parsed.taxesCents {
                    touched.insert(.taxes)
                    taxesCents = parsedTaxesCents
                }
                if let parsedNetPayCents = parsed.netPayCents {
                    touched.insert(.netPay)
                    netPayCents = parsedNetPayCents
                }
            }

            scanSnapshot = PaycheckScanSnapshot(
                touched: touched,
                amountCents: snapshotAmountCents,
                regularWagesCents: snapshotRegularWagesCents,
                overtimeWagesCents: snapshotOvertimeWagesCents,
                gratuityCents: snapshotGratuityCents,
                grossPayCents: snapshotGrossPayCents,
                taxesCents: snapshotTaxesCents,
                netPayCents: snapshotNetPayCents
            )
            setPaycheckScanSlotState(.scanned, resetAfter: 6)
            Self.scanLogger.notice(
                "Paycheck scan UI applied result. filledFields=\(parsed.filledFieldCount)"
            )
            PaydayHaptics.success()
        } catch {
            let errorType = String(describing: type(of: error))
            Self.scanLogger.error(
                "Paycheck scan UI received failure. type=\(errorType, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
            )
            scanSnapshot = nil
            setPaycheckScanSlotState(.error(error.localizedDescription), resetAfter: 4)
        }
    }

    private func save() {
        let effectiveRegularWagesCents = regularWagesCents > 0 ? regularWagesCents : nil
        let effectiveOvertimeWagesCents = overtimeWagesCents > 0 ? overtimeWagesCents : nil
        let effectiveGratuityCents = gratuityCents > 0 ? gratuityCents : nil
        let effectiveGrossPayCents = grossPayCents > 0 ? grossPayCents : nil
        let effectiveTaxesCents = taxesCents > 0 ? taxesCents : nil
        let effectiveNetPayCents = netPayCents > 0 ? netPayCents : nil

        let record: PaycheckRecord
        if let existing {
            existing.paidTipsCents = amountCents
            existing.note = note.isEmpty ? nil : note
            existing.regularWagesCents = effectiveRegularWagesCents
            existing.overtimeWagesCents = effectiveOvertimeWagesCents
            existing.gratuityCents = effectiveGratuityCents
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
                gratuityCents: effectiveGratuityCents,
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
    case gratuity
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
        .onChange(of: cents) { _, newValue in
            guard Int(digitsText) ?? 0 != newValue else { return }
            digitsText = newValue == 0 ? "" : String(newValue)
        }
    }
}

private enum PaycheckPhotoSource: String, Identifiable {
    case camera

    var id: String { rawValue }
}
