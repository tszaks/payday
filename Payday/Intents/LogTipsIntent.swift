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

    /// Requires an unlocked device. These intents can be dispatched from
    /// Siri, Shortcuts, the Action Button and Control Center, none of which
    /// traverse RootView — so without this the platform would happily run a
    /// financial read or write against a locked phone.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

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
        // Refuse rather than write. A mutation attributed to an account this
        // device is no longer signed into would sync up to that account the
        // moment someone signs back in.
        guard PaydayAuthorizationState.allowsFinancialAccess else {
            return .result(dialog: IntentDialog("Sign in to Payday first."))
        }
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

        // Siri is the surface where a write hurt most mid-transition: the
        // user says "log my tips", hears a confirmation, and sees nothing
        // until the server folds the row. Writes are records-only now.
        let completedIntoExistingShift = try logToRecords(in: context, today: today, cents: cents, tipOutCents: tipOutCents)

        let shiftRecords = try context.fetch(FetchDescriptor<ShiftRecord>())
        let paycheckRecords = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let preferencesStore = UserPreferencesStore()
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, shiftRecords: shiftRecords)
        PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: PayScheduleStore().schedule, shiftRecords: shiftRecords, paycheckRecords: paycheckRecords)
        PaydayWidgetRefresh.request()

        let kindText = kind.tipKind.displayName.lowercased()
        return .result(dialog: completedIntoExistingShift
            ? IntentDialog("Added \(Money.string(fromCents: cents)) in \(kindText) tips to today's shift.")
            : IntentDialog("Logged \(Money.string(fromCents: cents)) in \(kindText) tips."))
    }

    /// The new representation. Returns whether it completed an existing
    /// shift rather than starting one, which is the only thing the spoken
    /// confirmation needs to know.
    ///
    /// The completion rule is the record-side equivalent of
    /// `targetShiftID`: today's most recently recorded shift that does not
    /// already carry THIS kind of tip gets the amount, otherwise a new
    /// shift starts. Records mid-conversion are excluded from the candidates
    /// rather than mutated and allowed to throw, so Siri starts a fresh
    /// shift instead of failing outright on a `conversionPending` row.
    @MainActor
    private func logToRecords(in context: ModelContext, today: Date, cents: Int, tipOutCents: Int?) throws -> Bool {
        let todaysRecords = try context.fetch(FetchDescriptor<ShiftRecord>(predicate: #Predicate { $0.workDate == today }))
        let target = todaysRecords
            .filter { ShiftCommands.mayMutate($0) }
            .filter { kind.tipKind == .cash ? $0.cashTipsCents == 0 : $0.creditTipsCents == 0 }
            .max { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }

        if let target {
            // `update` touches the row, without which the edit never enters
            // the upload set. Assigning the one field leaves hours, sales,
            // period and clock times exactly as the shift already carried
            // them — the record model gives that for free, where the legacy
            // path below has to resolve and rewrite them to avoid dropping
            // any.
            try ShiftCommands.update(target, in: context) { record in
                if kind.tipKind == .cash {
                    record.cashTipsCents = cents
                } else {
                    record.creditTipsCents = cents
                }
                if let tipOutCents { record.tipOutCents = tipOutCents }
            }
            return true
        }

        _ = try ShiftCommands.create(
            in: context,
            workDate: today,
            cashTipsCents: kind.tipKind == .cash ? cents : 0,
            creditTipsCents: kind.tipKind == .credit ? cents : 0,
            tipOutCents: tipOutCents
        )
        return false
    }

}
