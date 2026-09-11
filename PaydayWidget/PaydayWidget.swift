import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct PaydayWidgetEntry: TimelineEntry {
    let date: Date
    let hasSchedule: Bool
    let periodTotalCents: Int
    let paceDeltaCents: Int?
    /// How many prior periods the pace delta is medianed over, so the
    /// VoiceOver label can say "usual pace" or "last period" accurately.
    let pacePeriodCount: Int
    let daysRemaining: Int
    let appearance: AppAppearance
    var relevance: TimelineEntryRelevance?
}

/// Reads the exact same shared store and stats engine as the app and the
/// intents — a widget number that ever disagreed with the app would be
/// worse than no widget at all.
struct PaydayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaydayWidgetEntry {
        PaydayWidgetEntry(date: .now, hasSchedule: true, periodTotalCents: 8600, paceDeltaCents: 1200, pacePeriodCount: 6, daysRemaining: 3, appearance: AppGroup.appearance, relevance: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaydayWidgetEntry) -> Void) {
        completion(buildEntries(at: [.now])[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaydayWidgetEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        var dates = [now]
        // A second, higher-relevance entry queued for tonight's shift window
        // so Smart Stack can surface Payday once logging is actually likely.
        if let evening = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now), evening > now {
            dates.append(evening)
        }
        let entries = buildEntries(at: dates)
        let nextMidnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: entries, policy: .after(nextMidnight)))
    }

    private func buildEntries(at dates: [Date]) -> [PaydayWidgetEntry] {
        guard let schedule = PayScheduleStore().schedule else {
            return dates.map {
                PaydayWidgetEntry(date: $0, hasSchedule: false, periodTotalCents: 0, paceDeltaCents: nil, pacePeriodCount: 0, daysRemaining: 0, appearance: AppGroup.appearance, relevance: nil)
            }
        }
        // Fetch once per provider request. Multiple timeline dates reuse the
        // same immutable snapshot instead of reopening and remapping the
        // complete shared history for each entry.
        let context = ModelContext(SharedModelContainer.shared)
        let allEntries = (try? context.fetch(FetchDescriptor<TipEntry>())) ?? []
        let engine = StatsEngine(records: allEntries.map(TipRecord.init))
        return dates.map {
            buildEntry(at: $0, schedule: schedule, allEntries: allEntries, engine: engine)
        }
    }

    private func buildEntry(at date: Date, schedule: PaySchedule, allEntries: [TipEntry], engine: StatsEngine) -> PaydayWidgetEntry {
        let calendar = Calendar.current
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date)
        let tipsTotal = engine.periodToDateTotal(period: period, asOf: date)

        // Same wage-inclusive total the dashboard hero shows — a widget
        // number that disagreed with the app would be worse than none.
        let periodEntries = allEntries.filter { $0.date >= period.start && $0.date <= period.end }
        let wages = PeriodIncome.wages(entries: periodEntries, wageCentsPerHour: AppGroup.baseHourlyWageCents, firstWeekday: schedule.firstWeekday)
        let total = tipsTotal + (wages?.totalCents ?? 0)

        // Same usual-pace baseline the Dashboard hero uses — the median of
        // the last several periods at this same point, not a race against
        // whichever single period came before.
        let comparison = engine.paceComparison(
            currentPeriod: period,
            priorPeriods: calculator.priorPeriods(before: period, count: StatsEngine.paceLookbackPeriods),
            asOf: date
        )

        let daysRemaining = calculator.daysRemaining(from: date)
        let isPaydayMoment = daysRemaining == 0 && total > 0
        let hour = calendar.component(.hour, from: date)
        let score: Float = isPaydayMoment ? 100 : ((17..<24).contains(hour) ? 70 : 30)

        return PaydayWidgetEntry(
            date: date,
            hasSchedule: true,
            periodTotalCents: total,
            paceDeltaCents: comparison?.deltaCents,
            pacePeriodCount: comparison?.periodCount ?? 0,
            daysRemaining: daysRemaining,
            appearance: AppGroup.appearance,
            relevance: TimelineEntryRelevance(score: score)
        )
    }
}

struct PaydayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PaydayWidgetEntry

    // WidgetKit owns the appearance independently of the app's saved theme.
    // Resolve colors from this host environment, including archived widgets.
    @Environment(\.colorScheme) private var colorScheme

    private var colors: PaydayWidgetColors { PaydayWidgetColors(scheme: colorScheme) }

    func comparisonColor(for cents: Int) -> Color {
        guard renderingMode == .fullColor else { return colors.textPrimary }
        if cents > 0 { return colors.primary }
        if cents < 0 { return colors.error }
        return colors.textSecondary
    }

    @ViewBuilder
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
                    .foregroundStyle(colors.textSecondary)
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
                                ? colors.onPrimary
                                : colors.textPrimary
                        )
                        .frame(width: 26, height: 26)
                        .background {
                            if renderingMode == .fullColor {
                                Circle().fill(colors.primary)
                            } else {
                                Circle().strokeBorder(colors.textPrimary.opacity(0.35), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log shift")
            }

            Spacer(minLength: 0)

            if entry.hasSchedule {
                Text(Money.string(fromCents: entry.periodTotalCents))
                    .font(PaydayFont.displayCompact)
                    .monospacedDigit()
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let paceDeltaCents = entry.paceDeltaCents {
                    Text(Money.directionalDeltaString(fromCents: paceDeltaCents))
                        .font(PaydayFont.caption2)
                        .foregroundStyle(comparisonColor(for: paceDeltaCents))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel(RevealCopy.paceLine(deltaCents: paceDeltaCents, periodCount: entry.pacePeriodCount))
                } else {
                    Text(daysRemainingText)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(colors.textSecondary)
                }
            } else {
                Text("Open Payday to set up your schedule")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .padding(PaydaySpacing.xs)
        .containerBackground(colors.background, for: .widget)
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
