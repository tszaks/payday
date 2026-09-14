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
        // Device authentication is the platform's half. This is Payday's:
        // the shared store still holds the cached earnings of whoever was
        // last signed in, and speaking that total to a signed-out device
        // would bypass the gate the app itself enforces.
        guard PaydayAuthorizationState.allowsFinancialAccess else {
            return .result(dialog: IntentDialog("Sign in to Payday first."))
        }
        guard let schedule = PayScheduleStore().schedule else {
            return .result(dialog: IntentDialog("Set up your pay schedule in Payday first."))
        }
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: .now)

        let entries = try SharedModelContainer.shared.mainContext.fetch(FetchDescriptor<TipEntry>())
        let engine = StatsEngine(records: entries.map(TipRecord.init))
        let tipsTotal = engine.periodToDateTotal(period: period, asOf: .now)

        // Same wage-inclusive total the dashboard hero shows — the spoken
        // number must match what's on screen.
        let periodEntries = entries.filter { $0.date >= period.start && $0.date <= period.end }
        let wages = PeriodIncome.wages(entries: periodEntries, wageCentsPerHour: AppGroup.baseHourlyWageCents, firstWeekday: schedule.firstWeekday)
        let total = tipsTotal + (wages?.totalCents ?? 0)

        return .result(dialog: IntentDialog("You've made \(Money.string(fromCents: total)) so far this pay period."))
    }
}
