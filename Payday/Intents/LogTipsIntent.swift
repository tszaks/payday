import AppIntents
import SwiftData

/// AppIntents' own enum type, distinct from the model's `TipKind` — keeps
/// the Siri/Shortcuts vocabulary decoupled from SwiftData.
enum TipKindAppEnum: String, AppEnum {
    case cash
    case credit

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Tip Kind")
    }

    static let caseDisplayRepresentations: [TipKindAppEnum: DisplayRepresentation] = [
        .cash: DisplayRepresentation(title: "Cash"),
        .credit: DisplayRepresentation(title: "Credit")
    ]

    var tipKind: TipKind {
        switch self {
        case .cash: .cash
        case .credit: .credit
        }
    }
}

/// Pure so the cents conversion + bounds can be unit tested without
/// invoking the intent itself. The UI's own CurrencyAmountField caps at
/// $99,999.99 (7 digits); Siri has no keypad to enforce that, so this
/// mirrors the same ceiling — and requires a positive amount, since "log
/// negative fifty dollars" would otherwise write negative cents and
/// corrupt every downstream total, pace line, and insight.
enum LogTipsAmountValidation {
    static let maximumCents = 99_999_99

    static func validatedCents(for amount: Double) -> Int? {
        let cents = Int((amount * 100).rounded())
        guard cents > 0, cents <= maximumCents else { return nil }
        return cents
    }
}

/// Siri/Shortcuts entry point for logging a tip without opening the app —
/// the "quiet intelligence" PRODUCT.md asks for. Runs entirely in the
/// background: Siri asks for the amount itself if it wasn't given, then
/// this writes straight to the shared store and confirms with a dialog.
/// Deliberately skips the reveal card (that's a SwiftUI, in-app moment) —
/// a spoken confirmation is the equivalent "verdict" for a hands-free log.
struct LogTipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Tips"
    static let description = IntentDescription("Log today's tips in Payday.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Amount", requestValueDialog: IntentDialog("How much did you make?"))
    var amount: Double

    @Parameter(title: "Kind", default: .cash)
    var kind: TipKindAppEnum

    /// Optional: "log $86 credit with a $15 tip-out." Kept off the main
    /// phrase (see parameterSummary) so the common case — just an amount —
    /// stays a one-line ask.
    @Parameter(title: "Tip-Out")
    var tipOut: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Log $\(\.$amount) in \(\.$kind) tips") {
            \.$tipOut
        }
    }

    /// Which shift this tip joins, given today's entries so far. Pure and
    /// unit-testable without SwiftData: the caller resolves "today's
    /// entries," this just decides among them.
    ///
    /// Every earlier invocation mints its own shiftID, so "log $200 credit"
    /// then "log $100 cash" a minute later — one real closeout — used to
    /// create TWO shifts, a phantom double corrupting the doubles analysis.
    /// The fix: complete today's most recent shift when it's missing this
    /// kind (nil return means "mint a fresh id" — this really is a new
    /// closeout, either because nothing was logged today yet, or because
    /// that kind is already present and this is a genuine second shift).
    /// Legacy rows with a nil shiftID can't be completed into.
    static func targetShiftID(existingToday: [(shiftID: UUID?, kind: TipKind, recordedAt: Date?)], kind: TipKind) -> UUID? {
        let latestShift = Dictionary(grouping: existingToday.filter { $0.shiftID != nil }, by: { $0.shiftID! })
            .map { shiftID, entries in (shiftID: shiftID, entries: entries) }
            .max { lhs, rhs in
                let lhsLatest = lhs.entries.compactMap(\.recordedAt).max() ?? .distantPast
                let rhsLatest = rhs.entries.compactMap(\.recordedAt).max() ?? .distantPast
                return lhsLatest < rhsLatest
            }
        guard let latestShift, !latestShift.entries.contains(where: { $0.kind == kind }) else { return nil }
        return latestShift.shiftID
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let cents = LogTipsAmountValidation.validatedCents(for: amount) else {
            throw $amount.needsValueError(IntentDialog("That doesn't sound right. How much did you actually make?"))
        }
        var tipOutCents: Int?
        if let tipOut {
            guard let validated = LogTipsAmountValidation.validatedCents(for: tipOut) else {
                throw $tipOut.needsValueError(IntentDialog("That tip-out doesn't sound right."))
            }
            tipOutCents = validated
        }

        let context = SharedModelContainer.shared.mainContext
        let today = Calendar.current.startOfDay(for: .now)
        let todaysEntries = try context.fetch(FetchDescriptor<TipEntry>(predicate: #Predicate { $0.date == today }))
        let existingToday = todaysEntries.map { (shiftID: $0.shiftID, kind: $0.kind, recordedAt: $0.recordedAt) }
        let completingShiftID = Self.targetShiftID(existingToday: existingToday, kind: kind.tipKind)
        let shiftID = completingShiftID ?? UUID()

        let entry = TipEntry(date: today, amountCents: cents, kind: kind.tipKind, recordedAt: .now, shiftID: shiftID)
        context.insert(entry)

        if let tipOutCents {
            // Resolve what the shift already has first — write only ever
            // overrides tipOutCents here, never silently drops hours/sales/
            // period/clock times a completed-into shift already carried.
            let shiftRows = completingShiftID != nil ? todaysEntries.filter { $0.shiftID == shiftID } + [entry] : [entry]
            let resolved = ShiftDetails.resolve(from: shiftRows)
            ShiftDetails.write(hoursWorked: resolved.hoursWorked, tipOutCents: tipOutCents, salesCents: resolved.salesCents, shiftPeriod: resolved.shiftPeriod, clockIn: resolved.clockIn, clockOut: resolved.clockOut, serverCount: resolved.serverCount, into: shiftRows)
        }

        try context.save()

        let allEntries = try context.fetch(FetchDescriptor<TipEntry>())
        let paycheckRecords = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let preferencesStore = UserPreferencesStore()
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries)
        PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: PayScheduleStore().schedule, allEntries: allEntries, paycheckRecords: paycheckRecords)
        PaydayWidgetRefresh.request()

        let kindText = kind.tipKind.displayName.lowercased()
        return .result(dialog: completingShiftID != nil
            ? IntentDialog("Added \(Money.string(fromCents: cents)) in \(kindText) tips to today's shift.")
            : IntentDialog("Logged \(Money.string(fromCents: cents)) in \(kindText) tips."))
    }
}
