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
    static let description = IntentDescription("Log tonight's tips in Payday.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Amount", requestValueDialog: IntentDialog("How much did you make?"))
    var amount: Double

    @Parameter(title: "Kind", default: .cash)
    var kind: TipKindAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Log $\(\.$amount) in \(\.$kind) tips")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let cents = LogTipsAmountValidation.validatedCents(for: amount) else {
            throw $amount.needsValueError(IntentDialog("That doesn't sound right. How much did you actually make?"))
        }
        let entry = TipEntry(
            date: Calendar.current.startOfDay(for: .now),
            amountCents: cents,
            kind: kind.tipKind,
            recordedAt: .now
        )
        let context = SharedModelContainer.shared.mainContext
        context.insert(entry)
        try context.save()

        let allEntries = try context.fetch(FetchDescriptor<TipEntry>())
        SmartNudgeScheduler.reschedule(preferencesStore: UserPreferencesStore(), allEntries: allEntries)
        PaydayWidgetRefresh.request()

        return .result(dialog: IntentDialog("Logged \(Money.string(fromCents: cents)) in \(kind.tipKind.displayName.lowercased()) tips."))
    }
}
