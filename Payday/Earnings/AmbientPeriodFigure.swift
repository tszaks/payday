import Foundation
import SwiftData

/// The pay-period figure the ambient surfaces show: the widget's faces and
/// Siri's spoken answer.
///
/// **One function, called by both, which is what makes "Siri == widget" a
/// property rather than two coincidences that have to be re-tested
/// separately.** Before this, each surface built its own `StatsEngine` and
/// then added wages through
/// `PeriodIncome.wages(..., wageCentsPerHour: AppGroup.baseHourlyWageCents,
/// firstWeekday: schedule.firstWeekday)` — the audit's original bug twice
/// over, on the two surfaces a user cannot refresh:
///
/// - a single scalar rate instead of the rate history, so a raise repriced
///   the whole period; and
/// - the CALENDAR's first weekday driving the overtime workweek instead of
///   the payroll calendar's, so the widget and the Dashboard could bucket
///   the same 45-hour week differently.
///
/// Both are recomputed in-process rather than read from a file the app wrote.
/// Intents and controls already write to the shared store from other
/// processes, so an app-written cache would be stale by construction.
@MainActor
enum AmbientPeriodFigure {
    /// Why there is no figure to show. Kept distinct because they read
    /// differently to a user: one is "finish setting up", the other is
    /// "something is wrong", and a surface that conflated them would tell
    /// somebody with a full history that they had never set the app up.
    enum Absence: Error, Equatable {
        case notAuthorized
        case noSchedule
        /// The engine could not answer. Never rendered as an amount.
        case unavailable
    }

    struct Answer {
        let figure: EarningsFigure
        let period: PayPeriod
        let daysRemaining: Int
    }

    static func current(
        now: Date = .now,
        requireFinancialAccess: Bool = true
    ) -> Result<Answer, Absence> {
        if requireFinancialAccess, !PaydayAuthorizationState.allowsFinancialAccess {
            return .failure(.notAuthorized)
        }
        let scheduleStore = PayScheduleStore()
        guard let schedule = scheduleStore.schedule else { return .failure(.noSchedule) }

        let policyStore = PolicyStore()
        let source = ModelContextEarningsInputSource(
            container: SharedModelContainer.shared,
            policyStore: policyStore,
            scheduleStore: scheduleStore
        )
        // Same rule as the app, not a smaller one. A Lock Screen or a spoken
        // answer reading $0 off a purged cache is the same lie in a smaller
        // font, which is why this is a parameter rather than an omission.
        guard case .success(let snapshot) = EarningsStore.buildOnce(
            source: source,
            shiftsAreAuthoritative: PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount
        ) else {
            return .failure(.unavailable)
        }

        return .success(answer(
            from: snapshot,
            schedule: schedule,
            payrollTimeZone: policyStore.payrollTimeZone,
            now: now
        ))
    }

    /// The figure logic, over a snapshot the caller already has.
    ///
    /// Split out for ONE reason: the widget's timeline asks for several dates
    /// per request, and `current` would rebuild the whole snapshot for each
    /// of them. The split keeps a single implementation of the part that must
    /// not diverge -- which query, which asOf, which label -- while letting
    /// the widget build once. Siri's convenience above and the widget both
    /// end up here.
    static func answer(
        from snapshot: EarningsSnapshot,
        schedule: PaySchedule,
        payrollTimeZone zone: TimeZone,
        now: Date
    ) -> Answer {
        let calculator = PayPeriodCalculator(payrollTimeZone: zone, schedule: schedule)
        let period = calculator.period(containing: now)

        // The same call the Dashboard hero makes, through the same helper, so
        // the amount AND the label are the app's rather than this surface's
        // opinion of them.
        let figure = EarningsFigure.earnedIncome(snapshot.payPeriod(
            DayRange(
                start: CivilDay(period.start, in: zone),
                end: CivilDay(period.end, in: zone)
            ),
            asOf: CivilDay(now, in: zone)
        ))

        return Answer(
            figure: figure,
            period: period,
            daysRemaining: calculator.daysRemaining(from: now)
        )
    }

    /// What Siri says.
    ///
    /// The label is spoken, not assumed: "You've made $X" is only true when
    /// the figure is a complete total. With a shift missing its hours the
    /// honest sentence names what is known, because a spoken number carries
    /// no caption to qualify it and is the one surface a user cannot re-read.
    static func spokenAnswer(now: Date = .now) -> String {
        switch current(now: now) {
        case .failure(.notAuthorized):
            return "Sign in to Payday first."
        case .failure(.noSchedule):
            return "Set up your pay schedule in Payday first."
        case .failure(.unavailable):
            return "Payday couldn't read your shifts right now."
        case .success(let answer):
            guard case .cents(let cents) = answer.figure.amount else {
                return "Payday couldn't read your shifts right now."
            }
            let amount = Money.string(fromCents: cents)
            if answer.figure.mayBeCalledATotal {
                return "You've made \(amount) so far this pay period."
            }
            return "\(answer.figure.label) this pay period is \(amount)."
        }
    }
}
