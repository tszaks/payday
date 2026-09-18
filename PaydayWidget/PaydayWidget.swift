import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct PaydayWidgetEntry: TimelineEntry {
    /// What this entry has to show.
    ///
    /// `periodTotalCents: Int` used to sit here, and that type was the bug:
    /// every failure path had to invent a number, and the number they all
    /// invented was 0. A Lock Screen reading "$0" off a store it could not
    /// open is the same lie as the app showing it, in a smaller font, on a
    /// surface the user cannot refresh.
    ///
    /// `EarningsFigure` already carries `.unavailable` as a case with no
    /// cents, so the lie is now unrepresentable rather than merely avoided.
    /// It also carries the LABEL, which is how this surface stops calling a
    /// wage-inclusive number "Tips".
    enum Content: Hashable, Sendable {
        /// No schedule yet, or ambient disclosure is not allowed. The widget
        /// shows its ordinary setup state rather than advertising that data
        /// exists behind a lock.
        case setup
        /// The engine's answer, including its own `.unavailable`.
        case figure(EarningsFigure)
    }

    let date: Date
    let content: Content
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
        PaydayWidgetEntry(
            date: .now,
            content: .figure(EarningsFigure(
                metric: .earnedIncome,
                amount: .cents(8_600),
                label: "Total",
                caption: nil,
                completeness: .empty
            )),
            paceDeltaCents: 1200, pacePeriodCount: 6, daysRemaining: 3,
            appearance: AppGroup.appearance, relevance: nil)
    }

    /// Both of these hop to the main actor before touching the engine.
    ///
    /// `EarningsStore.buildOnce` and `ModelContextEarningsInputSource` are
    /// `@MainActor` on purpose: SwiftData models must not cross to another
    /// isolation domain, and that rule does not relax because the caller is a
    /// widget. The completion-handler shape of `TimelineProvider` allows
    /// answering later, so this is a hop rather than an `assumeIsolated`,
    /// which would have been a claim about WidgetKit's threading that nothing
    /// in the API guarantees.
    func getSnapshot(in context: Context, completion: @escaping (PaydayWidgetEntry) -> Void) {
        let handoff = Handoff(call: completion)
        Task { @MainActor in handoff.call(Self.buildEntries(at: [.now])[0]) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaydayWidgetEntry>) -> Void) {
        let handoff = Handoff(call: completion)
        Task { @MainActor in Self.buildTimeline { handoff.call($0) } }
    }

    /// WidgetKit's completion closures are not `Sendable`, and the engine is
    /// `@MainActor`, so the two cannot meet without an explicit hand-off.
    ///
    /// Named and `@unchecked` rather than hidden behind a `MainActor
    /// .assumeIsolated`, which would be a claim about WidgetKit's threading
    /// that nothing in the API promises. The safety argument, so a reader can
    /// check it: the closure is stored, moved once, and invoked exactly once
    /// on the main actor. WidgetKit's contract is that the completion is
    /// called when the data is ready, not on a particular thread.
    private struct Handoff<Value>: @unchecked Sendable {
        let call: (Value) -> Void
    }

    @MainActor
    private static func buildTimeline(completion: @escaping (Timeline<PaydayWidgetEntry>) -> Void) {
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

    @MainActor
    private static func buildEntries(at dates: [Date]) -> [PaydayWidgetEntry] {
        // The widget is an ambient surface in its own process: it never
        // traverses RootView, so nothing here had ever consulted Payday's own
        // authorization policy. A signed-out or app-locked device would keep
        // rendering the last known period total, including on the Lock Screen.
        // Redacting by reusing the no-schedule entry means the widget shows
        // its ordinary setup state rather than advertising that data exists.
        guard PaydayAuthorizationState.allowsAmbientDisclosure else {
            return dates.map { Self.setupEntry(at: $0) }
        }
        let scheduleStore = PayScheduleStore()
        guard let schedule = scheduleStore.schedule else {
            return dates.map { Self.setupEntry(at: $0) }
        }
        // ONE snapshot, from the same engine the app uses, recomputed in this
        // process rather than read from a file the app wrote.
        //
        // The previous version built its own `StatsEngine` and then added
        // wages through `PeriodIncome.wages(..., wageCentsPerHour:
        // AppGroup.baseHourlyWageCents, firstWeekday: schedule.firstWeekday)`.
        // That is the audit's original bug on a live surface, twice over: a
        // single scalar rate instead of rate history, and the CALENDAR's first
        // weekday driving the overtime workweek instead of the payroll
        // calendar's. The widget could therefore disagree with the Dashboard
        // about the same pay period, and did.
        let policyStore = PolicyStore()
        let source = ModelContextEarningsInputSource(
            container: SharedModelContainer.shared,
            policyStore: policyStore,
            scheduleStore: scheduleStore
        )
        let snapshot: EarningsSnapshot
        switch EarningsStore.buildOnce(
            source: source,
            shiftsAreAuthoritative: PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount
        ) {
        case .success(let built):
            snapshot = built
        case .failure:
            // "Couldn't load", never $0. See Content.
            return dates.map { Self.unavailableEntry(at: $0) }
        }

        // StatsEngine is still the pace baseline, which is a COMPARISON and
        // not a money figure. Migrating that is group 2.6's job, not this
        // slice's, and mixing the two would make this change unreviewable.
        let context = ModelContext(SharedModelContainer.shared)
        let allEntries = (try? context.fetch(FetchDescriptor<TipEntry>())) ?? []
        let engine = StatsEngine(payrollTimeZone: policyStore.payrollTimeZone, records: allEntries.map(TipRecord.init))
        return dates.map {
            Self.buildEntry(at: $0, schedule: schedule, snapshot: snapshot, engine: engine, policyStore: policyStore)
        }
    }

    private static func setupEntry(at date: Date) -> PaydayWidgetEntry {
        PaydayWidgetEntry(
            date: date, content: .setup, paceDeltaCents: nil, pacePeriodCount: 0,
            daysRemaining: 0, appearance: AppGroup.appearance, relevance: nil)
    }

    private static func unavailableEntry(at date: Date) -> PaydayWidgetEntry {
        PaydayWidgetEntry(
            date: date, content: .figure(EarningsFigure.unavailable()),
            paceDeltaCents: nil, pacePeriodCount: 0, daysRemaining: 0,
            appearance: AppGroup.appearance, relevance: nil)
    }

    @MainActor
    private static func buildEntry(at date: Date, schedule: PaySchedule, snapshot: EarningsSnapshot, engine: StatsEngine, policyStore: PolicyStore) -> PaydayWidgetEntry {
        let calendar = Calendar.current
        // THE SAME FUNCTION SIRI CALLS. Not the same shape, the same
        // function: `AmbientPeriodFigure` owns which query, which asOf and
        // which label, so there is nothing for the widget and the spoken
        // answer to disagree about. The snapshot is passed in because a
        // timeline asks for several dates per request and rebuilding it per
        // date would be wasteful.
        let answer = AmbientPeriodFigure.answer(
            from: snapshot,
            schedule: schedule,
            payrollTimeZone: policyStore.payrollTimeZone,
            now: date
        )
        let figure = answer.figure
        let period = answer.period
        let calculator = PayPeriodCalculator(payrollTimeZone: policyStore.payrollTimeZone, schedule: schedule)
        let total: Int = {
            if case .cents(let cents) = figure.amount { return cents }
            return 0
        }()

        // Same usual-pace baseline the Dashboard hero uses — the median of
        // the last several periods at this same point, not a race against
        // whichever single period came before.
        let comparison = engine.paceComparison(
            currentPeriod: period,
            priorPeriods: calculator.priorPeriods(before: period, count: StatsEngine.paceLookbackPeriods),
            asOf: date
        )

        let daysRemaining = answer.daysRemaining
        let isPaydayMoment = daysRemaining == 0 && total > 0
        let hour = calendar.component(.hour, from: date)
        let score: Float = isPaydayMoment ? 100 : ((17..<24).contains(hour) ? 70 : 30)

        return PaydayWidgetEntry(
            date: date,
            content: .figure(figure),
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

    /// The cents, only when the engine answered. Setup and unavailable both
    /// give nil, and they render differently below because they mean
    /// different things.
    private var periodCents: Int? {
        guard case .figure(let figure) = entry.content,
              case .cents(let cents) = figure.amount else { return nil }
        return cents
    }

    /// The figure's own noun. Shown because this face used to print a bare
    /// amount whose basis a reader had to guess, and because "Known so far"
    /// is the difference between a total and a partial one.
    private var figureLabel: String? {
        guard case .figure(let figure) = entry.content else { return nil }
        return figure.label
    }

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

            if let cents = periodCents {
                if let label = figureLabel {
                    Text(label)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(colors.textSecondary)
                }
                // WidgetKit's own redaction, on top of the provider-level gate
                // above: this is what lets iOS blur the figure under the
                // system's Lock Screen privacy setting without Payday having
                // to predict that state itself.
                Text(Money.string(fromCents: cents))
                    .font(PaydayFont.displayCompact)
                    .monospacedDigit()
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .privacySensitive()

                if let paceDeltaCents = entry.paceDeltaCents {
                    Text(Money.directionalDeltaString(fromCents: paceDeltaCents))
                        .font(PaydayFont.caption2)
                        .foregroundStyle(comparisonColor(for: paceDeltaCents))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .privacySensitive()
                        .accessibilityLabel(RevealCopy.paceLine(deltaCents: paceDeltaCents, periodCount: entry.pacePeriodCount))
                } else {
                    Text(daysRemainingText)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(colors.textSecondary)
                }
            } else if case .figure = entry.content {
                // The engine could not answer. Never a currency string here:
                // this is the largest face, so a "$0.00" on it is the most
                // convincing version of the lie.
                Text("Couldn't load")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(colors.textSecondary)
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
