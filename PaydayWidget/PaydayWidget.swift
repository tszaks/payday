import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct PaydayWidgetEntry: TimelineEntry {
    let date: Date
    let hasSchedule: Bool
    let periodTotalCents: Int
    let paceDeltaCents: Int?
    let daysRemaining: Int
    var relevance: TimelineEntryRelevance?
}

/// Reads the exact same shared store and stats engine as the app and the
/// intents — a widget number that ever disagreed with the app would be
/// worse than no widget at all.
struct PaydayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaydayWidgetEntry {
        PaydayWidgetEntry(date: .now, hasSchedule: true, periodTotalCents: 8600, paceDeltaCents: 1200, daysRemaining: 3, relevance: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaydayWidgetEntry) -> Void) {
        completion(buildEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaydayWidgetEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        var entries = [buildEntry(at: now)]
        // A second, higher-relevance entry queued for tonight's shift window
        // so Smart Stack can surface Payday once logging is actually likely.
        if let evening = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now), evening > now {
            entries.append(buildEntry(at: evening))
        }
        let nextMidnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: entries, policy: .after(nextMidnight)))
    }

    private func buildEntry(at date: Date) -> PaydayWidgetEntry {
        guard let schedule = PayScheduleStore().schedule else {
            return PaydayWidgetEntry(date: date, hasSchedule: false, periodTotalCents: 0, paceDeltaCents: nil, daysRemaining: 0, relevance: nil)
        }
        let calendar = Calendar.current
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date)
        // A fresh, non-main-actor ModelContext — widget timeline generation
        // runs off the main actor, unlike the app's own SwiftUI-bound context.
        let context = ModelContext(SharedModelContainer.shared)
        let allEntries = (try? context.fetch(FetchDescriptor<TipEntry>())) ?? []
        let engine = StatsEngine(records: allEntries.map(TipRecord.init))
        let tipsTotal = engine.periodToDateTotal(period: period, asOf: date)

        // Same wage-inclusive total the dashboard hero shows — a widget
        // number that disagreed with the app would be worse than none.
        let periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        let wages = PeriodIncome.wages(entries: periodEntries, wageCentsPerHour: AppGroup.baseHourlyWageCents, firstWeekday: schedule.firstWeekday)
        let total = tipsTotal + (wages?.totalCents ?? 0)

        let previousDay = calendar.date(byAdding: .day, value: -1, to: period.start) ?? period.start
        let priorPeriod = calculator.period(containing: previousDay)
        let hasPriorHistory = allEntries.contains { $0.date >= priorPeriod.start && $0.date <= priorPeriod.end }
        let paceDelta = hasPriorHistory ? engine.paceDelta(currentPeriod: period, priorPeriod: priorPeriod, asOf: date) : nil

        let daysRemaining = calculator.daysRemaining(from: date)
        let isPaydayMoment = daysRemaining == 0 && total > 0
        let hour = calendar.component(.hour, from: date)
        let score: Float = isPaydayMoment ? 100 : ((17..<24).contains(hour) ? 70 : 30)

        return PaydayWidgetEntry(
            date: date,
            hasSchedule: true,
            periodTotalCents: total,
            paceDeltaCents: paceDelta,
            daysRemaining: daysRemaining,
            relevance: TimelineEntryRelevance(score: score)
        )
    }
}

struct PaydayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PaydayWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        case .accessoryRectangular:
            rectangularView
        default:
            homeScreenView
        }
    }

    // MARK: Home Screen (systemSmall)

    @Environment(\.widgetRenderingMode) private var renderingMode

    private var homeScreenView: some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.xxs) {
            HStack {
                Text("This period")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Spacer()
                Button(intent: OpenLogSheetIntent()) {
                    // In iOS 26's clear and tinted modes the system re-renders
                    // widget content monochrome, so a light glyph on a filled
                    // accent circle became white-on-white and the button read as
                    // a solid blank dot. Outside full colour, drop the fill and
                    // keep the affordance with a hairline ring instead.
                    Image(systemName: "plus")
                        .font(PaydayFont.iconSmall.weight(.bold))
                        .foregroundStyle(
                            renderingMode == .fullColor
                                ? PaydayColor.onPrimary
                                : PaydayColor.textPrimary
                        )
                        .frame(width: 26, height: 26)
                        .background {
                            if renderingMode == .fullColor {
                                Circle().fill(PaydayColor.primary)
                            } else {
                                Circle().strokeBorder(PaydayColor.textPrimary.opacity(0.35), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            if entry.hasSchedule {
                Text(Money.string(fromCents: entry.periodTotalCents))
                    .font(PaydayFont.displayCompact)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let paceDeltaCents = entry.paceDeltaCents {
                    Text(RevealCopy.compactPaceLine(deltaCents: paceDeltaCents))
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(daysRemainingText)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            } else {
                Text("Open Payday to set up your schedule")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .padding(PaydaySpacing.xs)
        .containerBackground(PaydayColor.background, for: .widget)
    }
}

struct PaydayWidget: Widget {
    let kind = "PaydayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaydayWidgetProvider()) { entry in
            PaydayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Payday")
        .description("This period's tip total, always in view.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct PaydayWidgetBundle: WidgetBundle {
    var body: some Widget {
        PaydayWidget()
        PaydayLogControl()
        PaydayStartShiftControl()
        PaydayEndShiftControl()
        ShiftLiveActivity()
    }
}
