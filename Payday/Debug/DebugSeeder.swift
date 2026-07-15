#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only sample data for screenshots and manual QA. Never compiled into
/// release builds. Seeds automatically when launched with `-SeedSampleData`,
/// or on demand from the Settings > Developer section.
enum DebugSeeder {
    @MainActor
    static func seedIfRequested(scheduleStore: PayScheduleStore, insightsStore: InsightsStore) {
        guard ProcessInfo.processInfo.arguments.contains("-SeedSampleData") else { return }
        seedSampleData(scheduleStore: scheduleStore, insightsStore: insightsStore)
    }

    @MainActor
    static func seedSampleData(scheduleStore: PayScheduleStore, insightsStore: InsightsStore) {
        let context = SharedModelContainer.shared.mainContext

        // Idempotent: reseeding always starts from a clean slate instead of
        // stacking duplicate entries on top of whatever was already there.
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        insightsStore.snapshot = nil

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let schedule = PaySchedule(
            frequency: .biweekly,
            // Period ended 9 days ago, paid 5 days later — same "most recent
            // payday" reference point as before (4 days ago) but now modeled
            // with a real lag, matching Tyler's actual schedule instead of
            // the old lag-unaware assumption.
            anchorPeriodEnd: calendar.date(byAdding: .day, value: -9, to: today) ?? today,
            payDelayDays: 5,
            firstWeekday: 2 // Monday, matching a Mon–Sun pay period
        )
        scheduleStore.schedule = schedule
        let calculator = PayPeriodCalculator(schedule: schedule)

        // hour = when the tip was recorded; dinner shifts (higher hours) tend
        // to earn more than lunch here so the time-of-day analysis has a signal.
        func recorded(daysAgo: Int, from anchor: Date, hour: Int, minute: Int) -> (day: Date, at: Date)? {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: anchor) else { return nil }
            let start = calendar.startOfDay(for: day)
            let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
            return (start, at)
        }

        let currentPeriod = calculator.period(containing: today)
        let sampleOffsets: [(daysAgo: Int, cents: Int, kind: TipKind, note: String?, hour: Int, minute: Int, isDouble: Bool)] = [
            (0, 8600, .credit, nil, 19, 20, false),
            (0, 3200, .cash, nil, 19, 25, false),
            (1, 11200, .credit, nil, 20, 5, true),
            (3, 6400, .cash, nil, 13, 10, false),
            (4, 9800, .credit, "lunch", 12, 45, false),
            (6, 7300, .cash, nil, 18, 40, false)
        ]
        for sample in sampleOffsets {
            guard let r = recorded(daysAgo: sample.daysAgo, from: today, hour: sample.hour, minute: sample.minute),
                  r.day >= currentPeriod.start else { continue }
            context.insert(TipEntry(date: r.day, amountCents: sample.cents, kind: sample.kind, note: sample.note, recordedAt: r.at, isDouble: sample.isDouble))
        }

        if let priorPeriodEnd = calendar.date(byAdding: .day, value: -1, to: currentPeriod.start) {
            let priorPeriod = calculator.period(containing: priorPeriodEnd)
            let priorOffsets: [(daysAgo: Int, cents: Int, kind: TipKind, note: String?, hour: Int, minute: Int, isDouble: Bool)] = [
                (2, 9100, .credit, nil, 19, 15, false),
                (4, 12300, .credit, nil, 20, 30, true),
                (6, 8800, .cash, nil, 18, 50, false),
                (8, 7600, .credit, "lunch", 12, 30, false),
                (10, 10400, .cash, nil, 13, 20, false)
            ]
            var loggedCreditTotal = 0
            for sample in priorOffsets {
                guard let r = recorded(daysAgo: sample.daysAgo, from: priorPeriod.end, hour: sample.hour, minute: sample.minute),
                      r.day >= priorPeriod.start, r.day <= priorPeriod.end else { continue }
                if sample.kind == .credit { loggedCreditTotal += sample.cents }
                context.insert(TipEntry(date: r.day, amountCents: sample.cents, kind: sample.kind, note: sample.note, recordedAt: r.at, isDouble: sample.isDouble))
            }
            // Paycheck reflects credit tips only (cash is walked nightly),
            // a hair under what was logged — a realistic small discrepancy.
            context.insert(PaycheckRecord(
                periodStart: priorPeriod.start,
                periodEnd: priorPeriod.end,
                paidTipsCents: loggedCreditTotal - 350,
                note: "Direct deposit"
            ))
        }

        try? context.save()
        PaydayWidgetRefresh.request()
    }

    @MainActor
    static func clearAll(scheduleStore: PayScheduleStore, insightsStore: InsightsStore) {
        let context = SharedModelContainer.shared.mainContext
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        try? context.save()
        PaydayWidgetRefresh.request()
        scheduleStore.schedule = nil
        insightsStore.snapshot = nil
    }
}
#endif
