#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only sample data for screenshots and manual QA. Never compiled into
/// release builds. Seeds automatically when launched with `-SeedSampleData`,
/// or on demand from the Settings > Developer section.
enum DebugSeeder {
    @MainActor
    static func seedIfRequested(scheduleStore: PayScheduleStore, insightsStore: InsightsStore, moveLedgerStore: MoveLedgerStore) {
        if ProcessInfo.processInfo.arguments.contains("-SeedSampleData") {
            seedSampleData(scheduleStore: scheduleStore, insightsStore: insightsStore)
        }
        if ProcessInfo.processInfo.arguments.contains("-SeedFollowUpDemo") {
            seedFollowUpDemoData(insightsStore: insightsStore, moveLedgerStore: moveLedgerStore)
        }
    }

    /// QA-only fixture for the Phase B "SINCE THEN" follow-up card: enough
    /// weeks of Friday/Monday history, split around a fabricated 35-day-old
    /// weekdaySwap ledger entry, that followUps() has a real behavior change
    /// and dollar effect to report. Not part of -SeedSampleData — that
    /// dataset stays small and representative of a real early user;
    /// exercising a 28-day-old follow-up needs its own dedicated history.
    @MainActor
    static func seedFollowUpDemoData(insightsStore: InsightsStore, moveLedgerStore: MoveLedgerStore) {
        let context = SharedModelContainer.shared.mainContext
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        insightsStore.snapshot = nil

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        func mostRecentWeekday(_ weekday: Int, onOrBefore date: Date) -> Date {
            var cursor = date
            while calendar.component(.weekday, from: cursor) != weekday {
                cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            }
            return cursor
        }
        let lastFriday = mostRecentWeekday(6, onOrBefore: today)
        let lastMonday = mostRecentWeekday(2, onOrBefore: today)

        func fridayWeeksAgo(_ weeks: Int) -> Date {
            calendar.date(byAdding: .day, value: -7 * weeks, to: lastFriday) ?? lastFriday
        }
        func mondayWeeksAgo(_ weeks: Int) -> Date {
            calendar.date(byAdding: .day, value: -7 * weeks, to: lastMonday) ?? lastMonday
        }
        func insertNight(_ date: Date, cents: Int) {
            let at = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: date) ?? date
            context.insert(TipEntry(date: date, amountCents: cents, kind: .credit, note: nil, recordedAt: at, isDouble: false, hoursWorked: 5.0, tipOutCents: nil, salesCents: nil, shiftPeriod: .dinner))
        }

        // BEFORE the move was shown (weeks 12 down to 5 ago): Friday every
        // other week, Monday every week — a real "before" pace establishing
        // Friday as the clear best-paying weekday.
        for week in stride(from: 12, through: 5, by: -1) {
            if week.isMultiple(of: 2) { insertNight(fridayWeeksAgo(week), cents: 15000) }
            insertNight(mondayWeeksAgo(week), cents: 8000)
        }
        // AFTER the move was shown (last 5 weeks): Friday every week, at a
        // slightly higher average — the behavior change and dollar effect
        // followUps() should catch.
        for week in stride(from: 4, through: 0, by: -1) {
            insertNight(fridayWeeksAgo(week), cents: 16000)
        }

        try? context.save()

        let shownAt = calendar.date(byAdding: .day, value: -35, to: today) ?? today
        moveLedgerStore.reset()
        moveLedgerStore.recordShown([Move(id: "weekdaySwap", title: "", body: "", annualImpactCents: 0)], now: shownAt)

        PaydayWidgetRefresh.request()
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
        // hoursWorked, tipOutCents, and shiftPeriod only ever sit on one
        // record per night (credit when a night has both, matching
        // LogTipSheet's convention) — otherwise StatsEngine's per-day
        // resolution would have two conflicting values to choose from.
        let sampleOffsets: [(daysAgo: Int, cents: Int, kind: TipKind, note: String?, hour: Int, minute: Int, isDouble: Bool, hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?)] = [
            (0, 8600, .credit, nil, 19, 20, false, 5.5, 1500, 43000, .dinner),
            (0, 3200, .cash, nil, 19, 25, false, nil, nil, nil, nil),
            (1, 11200, .credit, nil, 20, 5, true, 9.0, 2000, 56000, nil), // double — no single period applies
            (3, 6400, .cash, nil, 13, 10, false, 4.5, nil, 32000, .lunch),
            (4, 9800, .credit, "lunch", 12, 45, false, 4.0, 1000, 49000, .lunch),
            (6, 7300, .cash, nil, 18, 40, false, 5.0, nil, nil, .dinner)
        ]
        for sample in sampleOffsets {
            guard let r = recorded(daysAgo: sample.daysAgo, from: today, hour: sample.hour, minute: sample.minute),
                  r.day >= currentPeriod.start else { continue }
            context.insert(TipEntry(date: r.day, amountCents: sample.cents, kind: sample.kind, note: sample.note, recordedAt: r.at, isDouble: sample.isDouble, hoursWorked: sample.hoursWorked, tipOutCents: sample.tipOutCents, salesCents: sample.salesCents, shiftPeriod: sample.shiftPeriod))
        }

        if let priorPeriodEnd = calendar.date(byAdding: .day, value: -1, to: currentPeriod.start) {
            let priorPeriod = calculator.period(containing: priorPeriodEnd)
            let priorOffsets: [(daysAgo: Int, cents: Int, kind: TipKind, note: String?, hour: Int, minute: Int, isDouble: Bool, hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?)] = [
                (2, 9100, .credit, nil, 19, 15, false, 5.5, 1600, 45500, .dinner),
                (4, 12300, .credit, nil, 20, 30, true, 9.5, 2200, 61500, nil), // double
                (6, 8800, .cash, nil, 18, 50, false, 5.0, nil, 44000, .dinner),
                (8, 7600, .credit, "lunch", 12, 30, false, 4.0, 1000, 38000, .lunch),
                (10, 10400, .cash, nil, 13, 20, false, 4.5, nil, nil, .lunch)
            ]
            var loggedCreditTotal = 0
            for sample in priorOffsets {
                guard let r = recorded(daysAgo: sample.daysAgo, from: priorPeriod.end, hour: sample.hour, minute: sample.minute),
                      r.day >= priorPeriod.start, r.day <= priorPeriod.end else { continue }
                if sample.kind == .credit { loggedCreditTotal += sample.cents }
                context.insert(TipEntry(date: r.day, amountCents: sample.cents, kind: sample.kind, note: sample.note, recordedAt: r.at, isDouble: sample.isDouble, hoursWorked: sample.hoursWorked, tipOutCents: sample.tipOutCents, salesCents: sample.salesCents, shiftPeriod: sample.shiftPeriod))
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
    static func clearAll(scheduleStore: PayScheduleStore, insightsStore: InsightsStore, moveLedgerStore: MoveLedgerStore) {
        let context = SharedModelContainer.shared.mainContext
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        try? context.save()
        PaydayWidgetRefresh.request()
        scheduleStore.schedule = nil
        insightsStore.snapshot = nil
        moveLedgerStore.reset()
    }
}
#endif
