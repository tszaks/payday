import AppIntents
import SwiftData

/// Siri/Shortcuts read-only lookup — "How much have I made this period" —
/// answered entirely in the background, no app launch, same shared store
/// and stats engine as everywhere else so the number always matches the app.
struct PeriodTotalIntent: AppIntent {
    static let title: LocalizedStringResource = "Period Tip Total"
    static let description = IntentDescription("Hear your tip total for the current pay period.")
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let schedule = PayScheduleStore().schedule else {
            return .result(dialog: IntentDialog("Set up your pay schedule in Payday first."))
        }
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: .now)

        let entries = try SharedModelContainer.shared.mainContext.fetch(FetchDescriptor<TipEntry>())
        let engine = StatsEngine(records: entries.map(TipRecord.init))
        let total = engine.periodToDateTotal(period: period, asOf: .now)

        return .result(dialog: IntentDialog("You've made \(Money.string(fromCents: total)) so far this pay period."))
    }
}
