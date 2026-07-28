#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only sample data for screenshots and manual QA. Never compiled into
/// release builds. Seeds automatically when launched with `-SeedSampleData`,
/// or on demand from the Settings > Developer section.
enum DebugSeeder {
    @MainActor
    static func seedIfRequested(scheduleStore: PayScheduleStore, insightsStore: InsightsStore, moveLedgerStore: MoveLedgerStore, preferencesStore: UserPreferencesStore) {
        if ProcessInfo.processInfo.arguments.contains("-SeedSampleData") {
            seedSampleData(scheduleStore: scheduleStore, insightsStore: insightsStore)
        }
        if ProcessInfo.processInfo.arguments.contains("-SeedFollowUpDemo") {
            seedFollowUpDemoData(insightsStore: insightsStore, moveLedgerStore: moveLedgerStore)
        }
        if ProcessInfo.processInfo.arguments.contains("-SeedColdStart") {
            seedColdStartData(scheduleStore: scheduleStore, insightsStore: insightsStore)
        }
        if ProcessInfo.processInfo.arguments.contains("-SeedShowcase") {
            seedShowcaseData(scheduleStore: scheduleStore, insightsStore: insightsStore, preferencesStore: preferencesStore)
        }
    }

    /// Six months of plausible history for App Store screenshots: a
    /// Wed-through-Sun server at a dinner house, with lunch doubles on
    /// weekends, a summer that builds, and enough hours/sales/tip-outs
    /// logged that every gated insight (weekday reads, $/hr, tip percent,
    /// Moves, plan-forward) actually clears its honesty threshold.
    /// Deterministic: a seeded generator, so every screenshot run renders
    /// identical numbers.
    @MainActor
    static func seedShowcaseData(scheduleStore: PayScheduleStore, insightsStore: InsightsStore, preferencesStore: UserPreferencesStore) {
        let context = SharedModelContainer.shared.mainContext
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        insightsStore.snapshot = nil

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        preferencesStore.baseHourlyWageCents = 283
        preferencesStore.firstName = "Alex"
        // A leftover live session from QA would put "On shift" in every
        // screenshot — this fixture owns a clean slate.
        ShiftSessionStore.endActive(stash: false)

        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: calendar.date(byAdding: .day, value: -9, to: today) ?? today,
            payDelayDays: 5,
            firstWeekday: 2
        )
        scheduleStore.schedule = schedule
        let calculator = PayPeriodCalculator(schedule: schedule)

        // Deterministic pseudo-random: same screenshots every run.
        var seed: UInt64 = 0x5EED_0DAD
        func next(_ upperBound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, upperBound)))
        }
        func jitter(_ base: Int, _ spread: Int) -> Int { base + next(spread * 2) - spread }

        /// Weekday earning personality: Friday and Saturday dinners carry
        /// the week, Wednesday is the quiet night, Sunday brunch runs
        /// cash-heavy — a real-looking shape, not noise.
        func dinnerBase(weekday: Int) -> Int {
            switch weekday {
            case 4: return 15500   // Wednesday
            case 5: return 19000   // Thursday
            case 6: return 27500   // Friday
            case 7: return 30500   // Saturday
            case 1: return 21000   // Sunday
            default: return 18000
            }
        }
        func cashShare(weekday: Int) -> Double { weekday == 1 ? 0.42 : 0.16 }

        var day = calendar.date(byAdding: .month, value: -6, to: today) ?? today
        while day <= today {
            let weekday = calendar.component(.weekday, from: day)
            let worksToday = [4, 5, 6, 7, 1].contains(weekday)
            guard worksToday, next(100) > 12 else {   // ~12% of shifts off
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                continue
            }

            // Summer builds: a gentle upward ramp across the six months,
            // with the current period running a little hot so the pace line
            // reads "ahead of last period" in store screenshots.
            let monthsIn = Double(calendar.dateComponents([.month], from: day, to: today).month ?? 0)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let recentBoost = daysAgo <= 14 ? 1.18 : 1.0
            let ramp = (1.0 + (6.0 - monthsIn) * 0.02) * recentBoost

            // Weekend lunch double.
            if [6, 7, 1].contains(weekday), next(100) < 45 {
                let lunchGross = Int(Double(jitter(9500, 2200)) * ramp)
                insertShift(context: context, day: day, grossCents: lunchGross,
                            cashFraction: cashShare(weekday: weekday) + 0.1,
                            clockIn: (10, 30), clockOut: (15, 15),
                            tipOutCents: Int(Double(lunchGross) * 0.11),
                            salesCents: lunchGross * 9, period: .lunch, calendar: calendar, next: next)
            }

            let dinnerGross = Int(Double(jitter(dinnerBase(weekday: weekday), 5200)) * ramp)
            insertShift(context: context, day: day, grossCents: dinnerGross,
                        cashFraction: cashShare(weekday: weekday),
                        clockIn: (16, 45), clockOut: (23, 15),
                        tipOutCents: Int(Double(dinnerGross) * 0.12),
                        salesCents: dinnerGross * 8, period: .dinner, calendar: calendar, next: next)

            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }
        try? context.save()

        // Verified paychecks for every closed period but the most recent —
        // so the paycheck surfaces have real history to show.
        let allEntries = (try? context.fetch(FetchDescriptor<TipEntry>())) ?? []
        var cursor = calculator.period(containing: calendar.date(byAdding: .day, value: -14, to: today) ?? today)
        for _ in 0..<11 {
            let periodEntries = allEntries.filter { $0.date >= cursor.start && $0.date <= cursor.end }
            let creditCents = TipBreakdown.total(of: periodEntries).creditCents
            if creditCents > 0 {
                context.insert(PaycheckRecord(
                    periodStart: cursor.start,
                    periodEnd: cursor.end,
                    paidTipsCents: creditCents,
                    note: "Direct deposit"
                ))
            }
            guard let previousEnd = calendar.date(byAdding: .day, value: -1, to: cursor.start) else { break }
            cursor = calculator.period(containing: previousEnd)
        }
        try? context.save()
        PaydayWidgetRefresh.request()
    }

    /// One closeout: cash + credit rows sharing a shiftID, with the
    /// shift-level facts on the canonical entry (see ShiftDetails).
    @MainActor
    private static func insertShift(
        context: ModelContext,
        day: Date,
        grossCents: Int,
        cashFraction: Double,
        clockIn: (Int, Int),
        clockOut: (Int, Int),
        tipOutCents: Int,
        salesCents: Int,
        period: ShiftPeriod,
        calendar: Calendar,
        next: (Int) -> Int
    ) {
        // Cash walks out in bills — round the cash side to whole dollars.
        let cashCents = Int((Double(grossCents) * cashFraction / 100.0).rounded()) * 100
        let creditCents = grossCents - cashCents
        let inDate = calendar.date(bySettingHour: clockIn.0, minute: clockIn.1, second: 0, of: day) ?? day
        let outDate = calendar.date(bySettingHour: clockOut.0, minute: clockOut.1, second: 0, of: day) ?? day
        let recordedAt = calendar.date(byAdding: .minute, value: 20, to: outDate) ?? outDate
        let hours = ShiftTimes.hours(clockIn: inDate, clockOut: outDate)
        let shiftID = UUID()

        var entries: [TipEntry] = []
        if cashCents > 0 {
            let entry = TipEntry(date: day, amountCents: cashCents, kind: .cash, note: nil, recordedAt: recordedAt, shiftID: shiftID)
            context.insert(entry)
            entries.append(entry)
        }
        if creditCents > 0 {
            let entry = TipEntry(date: day, amountCents: creditCents, kind: .credit, note: nil, recordedAt: recordedAt, shiftID: shiftID)
            context.insert(entry)
            entries.append(entry)
        }
        ShiftDetails.write(hoursWorked: hours, tipOutCents: tipOutCents, salesCents: salesCents, shiftPeriod: period, clockIn: inDate, clockOut: outDate, serverCount: 4 + next(3), into: entries)
    }

    /// QA-only fixture for the cold-start surfaces: exactly 3 shifts, below
    /// the 5-shift Insights gate, so the empty state's progress bar and
    /// unlock line (see UnlockProgress) can be rendered honestly —
    /// -SeedSampleData is already past every gate and can't show them.
    @MainActor
    static func seedColdStartData(scheduleStore: PayScheduleStore, insightsStore: InsightsStore) {
        let context = SharedModelContainer.shared.mainContext
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        insightsStore.snapshot = nil

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        scheduleStore.schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: calendar.date(byAdding: .day, value: -9, to: today) ?? today,
            payDelayDays: 5,
            firstWeekday: 2
        )

        for (daysAgo, cents) in [(1, 14200), (3, 9800), (6, 11600)] {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let at = calendar.date(bySettingHour: 21, minute: 30, second: 0, of: day) ?? day
            context.insert(TipEntry(date: day, amountCents: cents, kind: .credit, note: nil, recordedAt: at, shiftID: UUID()))
        }

        try? context.save()
        PaydayWidgetRefresh.request()
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
            context.insert(TipEntry(date: date, amountCents: cents, kind: .credit, note: nil, recordedAt: at, hoursWorked: 5.0, tipOutCents: nil, salesCents: nil, shiftPeriod: .dinner, shiftID: UUID()))
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

        // Start/end clock times for the start-time analysis (see StatsEngine
        // startTimeFacts): always land on the same tuple row that already
        // holds hoursWorked — the canonical rule ShiftDetails enforces for
        // real logging, since only one record per shift ever carries these
        // shift-level facts. Lunch starts ~11:00, dinner starts ~17:00, and
        // every clockOut below is picked so ShiftTimes' exact-minute math
        // reproduces the hoursWorked already in these fixtures.
        func clockTime(hour: Int, minute: Int, on day: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let currentPeriod = calculator.period(containing: today)
        // `shift` groups rows into closeouts: rows sharing one shift index are
        // one shift (e.g. a cash+credit night), and two shifts on the same
        // day make an emergent double. hoursWorked/tipOut/sales/period sit on
        // one record per shift (credit preferred), matching LogTipSheet.
        let sampleOffsets: [(daysAgo: Int, cents: Int, kind: TipKind, note: String?, hour: Int, minute: Int, shift: Int, hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?, clockInHour: Int?, clockInMinute: Int, clockOutHour: Int?, clockOutMinute: Int)] = [
            (0, 8600, .credit, nil, 19, 20, 0, 5.5, 1500, 43000, .dinner, 17, 0, 22, 30),
            (0, 3200, .cash, nil, 19, 25, 0, nil, nil, nil, nil, nil, 0, nil, 0),
            // A real double on daysAgo 1: a lunch closeout AND a dinner closeout.
            (1, 5200, .cash, nil, 13, 30, 1, 4.0, nil, 26000, .lunch, 11, 0, 15, 0),
            (1, 6000, .credit, nil, 20, 5, 2, 5.0, 2000, 30000, .dinner, 17, 0, 22, 0),
            (3, 6400, .cash, nil, 13, 10, 3, 4.5, nil, 32000, .lunch, 11, 0, 15, 30),
            (4, 9800, .credit, "lunch", 12, 45, 4, 4.0, 1000, 49000, .lunch, 11, 0, 15, 0),
            (6, 7300, .cash, nil, 18, 40, 5, 5.0, nil, nil, .dinner, 17, 0, 22, 0)
        ]
        var currentShiftIDs: [Int: UUID] = [:]
        for sample in sampleOffsets {
            guard let r = recorded(daysAgo: sample.daysAgo, from: today, hour: sample.hour, minute: sample.minute),
                  r.day >= currentPeriod.start else { continue }
            let shiftID = currentShiftIDs[sample.shift] ?? {
                let id = UUID(); currentShiftIDs[sample.shift] = id; return id
            }()
            let clockIn = sample.clockInHour.map { clockTime(hour: $0, minute: sample.clockInMinute, on: r.day) }
            let clockOut = sample.clockOutHour.map { clockTime(hour: $0, minute: sample.clockOutMinute, on: r.day) }
            context.insert(TipEntry(date: r.day, amountCents: sample.cents, kind: sample.kind, note: sample.note, recordedAt: r.at, hoursWorked: sample.hoursWorked, tipOutCents: sample.tipOutCents, salesCents: sample.salesCents, shiftPeriod: sample.shiftPeriod, shiftID: shiftID, clockIn: clockIn, clockOut: clockOut))
        }

        if let priorPeriodEnd = calendar.date(byAdding: .day, value: -1, to: currentPeriod.start) {
            let priorPeriod = calculator.period(containing: priorPeriodEnd)
            let priorOffsets: [(daysAgo: Int, cents: Int, kind: TipKind, note: String?, hour: Int, minute: Int, shift: Int, hoursWorked: Double?, tipOutCents: Int?, salesCents: Int?, shiftPeriod: ShiftPeriod?, clockInHour: Int?, clockInMinute: Int, clockOutHour: Int?, clockOutMinute: Int)] = [
                (2, 9100, .credit, nil, 19, 15, 0, 5.5, 1600, 45500, .dinner, 17, 0, 22, 30),
                // A real double on daysAgo 4: a lunch closeout AND a dinner closeout.
                (4, 5800, .cash, nil, 13, 15, 1, 4.5, nil, 29000, .lunch, 11, 0, 15, 30),
                (4, 6500, .credit, nil, 20, 30, 2, 5.0, 2200, 32500, .dinner, 17, 0, 22, 0),
                (6, 8800, .cash, nil, 18, 50, 3, 5.0, nil, 44000, .dinner, 17, 0, 22, 0),
                (8, 7600, .credit, "lunch", 12, 30, 4, 4.0, 1000, 38000, .lunch, 11, 0, 15, 0),
                (10, 10400, .cash, nil, 13, 20, 5, 4.5, nil, nil, .lunch, 11, 0, 15, 30)
            ]
            var priorShiftIDs: [Int: UUID] = [:]
            var loggedCreditTotal = 0
            for sample in priorOffsets {
                guard let r = recorded(daysAgo: sample.daysAgo, from: priorPeriod.end, hour: sample.hour, minute: sample.minute),
                      r.day >= priorPeriod.start, r.day <= priorPeriod.end else { continue }
                if sample.kind == .credit { loggedCreditTotal += sample.cents }
                let shiftID = priorShiftIDs[sample.shift] ?? {
                    let id = UUID(); priorShiftIDs[sample.shift] = id; return id
                }()
                let clockIn = sample.clockInHour.map { clockTime(hour: $0, minute: sample.clockInMinute, on: r.day) }
                let clockOut = sample.clockOutHour.map { clockTime(hour: $0, minute: sample.clockOutMinute, on: r.day) }
                context.insert(TipEntry(date: r.day, amountCents: sample.cents, kind: sample.kind, note: sample.note, recordedAt: r.at, hoursWorked: sample.hoursWorked, tipOutCents: sample.tipOutCents, salesCents: sample.salesCents, shiftPeriod: sample.shiftPeriod, shiftID: shiftID, clockIn: clockIn, clockOut: clockOut))
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
