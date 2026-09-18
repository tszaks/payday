import AppIntents
import SwiftData

/// Siri/Shortcuts read-only lookup — "How much have I made this period" —
/// answered entirely in the background, no app launch, same shared store
/// and stats engine as everywhere else so the number always matches the app.
struct PeriodTotalIntent: AppIntent {
    static let title: LocalizedStringResource = "Period Tip Total"
    static let description = IntentDescription("Hear your tip total for the current pay period.")
    static var openAppWhenRun: Bool { false }

    /// Requires an unlocked device. These intents can be dispatched from
    /// Siri, Shortcuts, the Action Button and Control Center, none of which
    /// traverse RootView — so without this the platform would happily run a
    /// financial read or write against a locked phone.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Every decision here -- the authorization gate, the schedule check,
        // the engine query, the label, and therefore the sentence -- lives in
        // AmbientPeriodFigure, which the widget also calls. That is what makes
        // "Siri == widget" structural: there is one path, so there is nothing
        // for the two to disagree about.
        //
        // What this replaced built a second StatsEngine and added wages from a
        // scalar rate with the CALENDAR's first weekday, so the spoken number
        // could differ from the number on screen. On a spoken surface that is
        // the worst place for it: there is no caption, and the user cannot
        // re-read it.
        .result(dialog: IntentDialog(stringLiteral: AmbientPeriodFigure.spokenAnswer()))
    }
}
