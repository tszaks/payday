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
        guard let container = try? ModelContainer(for: TipEntry.self, PaycheckRecord.self) else { return }
        let context = container.mainContext

        // Idempotent: reseeding always starts from a clean slate instead of
        // stacking duplicate entries on top of whatever was already there.
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        insightsStore.snapshot = nil

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPayday: calendar.date(byAdding: .day, value: -4, to: today) ?? today
        )
        scheduleStore.schedule = schedule
        let calculator = PayPeriodCalculator(schedule: schedule)

        let currentPeriod = calculator.period(containing: today)
        let sampleOffsets: [(daysAgo: Int, cents: Int, note: String?)] = [
            (0, 8600, nil),
            (1, 11200, "double"),
            (3, 6400, nil),
            (4, 9800, "lunch"),
            (6, 7300, nil)
        ]
        for sample in sampleOffsets {
            guard let date = calendar.date(byAdding: .day, value: -sample.daysAgo, to: today),
                  date >= currentPeriod.start else { continue }
            context.insert(TipEntry(date: calendar.startOfDay(for: date), amountCents: sample.cents, note: sample.note))
        }

        if let priorPeriodEnd = calendar.date(byAdding: .day, value: -1, to: currentPeriod.start) {
            let priorPeriod = calculator.period(containing: priorPeriodEnd)
            let priorOffsets: [(daysAgo: Int, cents: Int, note: String?)] = [
                (2, 9100, nil),
                (4, 12300, "double"),
                (6, 8800, nil),
                (8, 7600, "lunch"),
                (10, 10400, nil)
            ]
            var loggedTotal = 0
            for sample in priorOffsets {
                guard let date = calendar.date(byAdding: .day, value: -sample.daysAgo, to: priorPeriod.end),
                      date >= priorPeriod.start, date <= priorPeriod.end else { continue }
                loggedTotal += sample.cents
                context.insert(TipEntry(date: calendar.startOfDay(for: date), amountCents: sample.cents, note: sample.note))
            }
            context.insert(PaycheckRecord(
                periodStart: priorPeriod.start,
                periodEnd: priorPeriod.end,
                paidTipsCents: loggedTotal - 350,
                note: "Direct deposit"
            ))
        }

        try? context.save()
    }

    @MainActor
    static func clearAll(scheduleStore: PayScheduleStore, insightsStore: InsightsStore) {
        guard let container = try? ModelContainer(for: TipEntry.self, PaycheckRecord.self) else { return }
        let context = container.mainContext
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        try? context.save()
        scheduleStore.schedule = nil
        insightsStore.snapshot = nil
    }
}
#endif
