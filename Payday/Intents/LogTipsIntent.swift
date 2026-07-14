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
        let cents = Int((amount * 100).rounded())
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

        return .result(dialog: IntentDialog("Logged \(Money.string(fromCents: cents)) in \(kind.tipKind.displayName.lowercased()) tips."))
    }
}
