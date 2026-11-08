import SwiftData
import SwiftUI

/// Settings > Payroll: the rate, the rate's history, the workweek the
/// overtime threshold is counted over, the optional daily overtime rule, and
/// the payroll time zone those civil days are measured in (PaydayCore Design 1).
///
/// It is a section rather than its own screen because these four facts are
/// read together: "what am I paid, since when, over which week, in which
/// zone" is one question. The estimate disclaimer is part of the section for
/// the same reason — the overtime rules this engine supports (1.5x past 40
/// hours in a workweek, and optionally past 8 hours in a payroll day, with no
/// double time) are an estimate, not a guarantee about anybody's state or
/// employer, and the number is labelled where it is produced rather than in
/// an About screen nobody opens.
struct PayrollSettingsSection: View {
    @Environment(PolicyStore.self) private var policyStore
    @Environment(UserPreferencesStore.self) private var preferencesStore

    /// Shifts on file, for the one-time rate-history prompt: a brand-new user
    /// with no history has nothing to be asked about.
    let shiftCount: Int

    @State private var wageDigitsText = ""
    @FocusState private var isWageFieldFocused: Bool
    @State private var workweekStartWeekday = 1
    @State private var isShowingRateChange = false
    @State private var isShowingZoneChange = false
    /// The role whose rate sheet is open, if any.
    @State private var editingRole: RoleRateEdit?

    /// Read for their roles only, so Roles and rates can appear once a shift
    /// has a role, before any role has a rate.
    @Query private var shiftRecords: [ShiftRecord]

    /// The account's roles: on shifts (most recent first), then any that
    /// only a rate policy names. Empty means no roles, and then the section
    /// does not exist.
    private var roleNames: [String] {
        var names = ShiftRoleList.byRecency(ShiftRoleList.entries(shiftRecords))
        for name in policyStore.policies.roleNames where !names.contains(where: { ShiftRoleList.matches($0, name) }) {
            names.append(name)
        }
        return names
    }

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    private var today: CivilDay {
        CivilDay(.now, in: policyStore.payrollTimeZone)
    }

    /// The rate the row shows and the row's field edits: the rate POLICY's,
    /// never `UserPreferencesStore.baseHourlyWageCents`.
    ///
    /// `docs/METRICS.md` [ST-01] is group 2.15's single row, and this is it.
    /// The legacy scalar is now a one-way MIRROR of this value, written on
    /// every edit below only because the shipped 1.0 build, the widget and
    /// the Siri intent still read it (PR 6 removes those readers). Nothing in
    /// Settings reads it back, so there is one rate on screen and not two.
    ///
    /// **`latestRate` and not `policies.rate(on: today)`, deliberately.**
    /// The contract's "never `latestCalendar`" rule is about MONEY paths: a
    /// queued future workweek re-buckets history today. This is not a money
    /// path — it is the policy input itself, with no `MetricID`, no
    /// completeness and no cents derived from it here — and the editor
    /// (`PolicyStore.applyRateEdit`) rewrites `latestRate` IN PLACE so that
    /// correcting a typo never invents a raise. Display and editor must name
    /// the same policy or typing in this row silently edits a policy the row
    /// is not showing. They are also the same value for every policy set the
    /// UI can produce: `RateChangeSheet`'s date picker is bounded
    /// `in: ...Date.now`, so no rate policy is ever effective in the future.
    /// `SettingsWageRowTests` pins both halves of that.
    private var currentRateCents: Int? { policyStore.currentHourlyRateCents }

    private var isRateHistoryPromptOwed: Bool {
        policyStore.owesRateHistoryPrompt(shiftCount: shiftCount)
    }

    var body: some View {
        Group {
            if isRateHistoryPromptOwed, let rate = currentRateCents {
                rateHistoryPrompt(rate: rate)
            }
            payrollSection
            rolesSection
        }
        .onAppear(perform: load)
        .onChange(of: wageDigitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxWageDigits))
            if filtered != newValue { wageDigitsText = filtered }
            let cents = Self.rateCents(fromDigits: filtered)
            // MEASURED on the simulator: without this guard, `load()` writing
            // the current rate into `wageDigitsText` on appear fired this
            // handler, which called `applyRateEdit` and marked the policy
            // `.confirmed`. Merely OPENING Settings answered the rate-history
            // prompt — the "estimated" caption vanished and the question was
            // never asked. A no-op edit is not an edit.
            guard cents != policyStore.currentHourlyRateCents else { return }
            // `baseHourlyWageCents` is a read-only VIEW of the rate policy
            // from here on (PR 6 removes its last readers), but it is still
            // what the shipped 1.0 build, the widget and the Siri intent
            // read, so the policy and the mirror move together or a Lock
            // Screen would quote a rate the app no longer uses.
            policyStore.applyRateEdit(hourlyRateCents: cents)
            preferencesStore.baseHourlyWageCents = cents
        }
        .onChange(of: workweekStartWeekday) { oldValue, newValue in
            guard oldValue != newValue else { return }
            policyStore.applyCalendarChange(
                workweekStartWeekday: newValue,
                payrollTimeZone: policyStore.payrollTimeZone,
                today: today
            )
        }
        .sheet(isPresented: $isShowingRateChange) {
            RateChangeSheet(currentRateCents: currentRateCents) { cents, day in
                guard let day else { return }
                policyStore.applyRateChange(hourlyRateCents: cents, effectiveFrom: day)
                preferencesStore.baseHourlyWageCents = policyStore.currentHourlyRateCents
                load()
            }
            .paydayAppearance()
        }
        .sheet(item: $editingRole) { edit in
            RateChangeSheet(
                currentRateCents: policyStore.currentRateCents(forRole: edit.role),
                title: "\(edit.role) Rate",
                asksForDate: policyStore.currentRateCents(forRole: edit.role) != nil
            ) { cents, day in
                if let day {
                    policyStore.applyRoleRateChange(role: edit.role, hourlyRateCents: cents, effectiveFrom: day)
                } else {
                    policyStore.applyRoleRateEdit(role: edit.role, hourlyRateCents: cents)
                }
            }
            .paydayAppearance()
        }
    }

    // MARK: Sections

    /// "Roles and rates": one rate per role. Appears only once a role exists,
    /// on a shift or in a rate, so an account without roles sees today's
    /// Settings. The existing rate is "All roles" and stays the default: a
    /// role with no rate of its own is paid at it, and removing a role's rate
    /// falls back to it rather than to zero.
    @ViewBuilder
    private var rolesSection: some View {
        let roles = roleNames
        if !roles.isEmpty {
            Section {
                HStack {
                    Text("All roles")
                        .foregroundStyle(PaydayColor.textPrimary)
                    Spacer()
                    Text(Self.rateDisplay(currentRateCents))
                        .foregroundStyle(currentRateCents == nil ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                ForEach(roles, id: \.self) { role in
                    let rate = policyStore.currentRateCents(forRole: role)
                    Button {
                        editingRole = RoleRateEdit(role: role)
                    } label: {
                        HStack {
                            Text(role)
                                .foregroundStyle(PaydayColor.textPrimary)
                            Spacer()
                            Text(rate.map { Money.string(fromCents: $0) } ?? "All roles rate")
                                .foregroundStyle(rate == nil ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                                .monospacedDigit()
                        }
                    }
                    .swipeActions {
                        if rate != nil {
                            Button("Remove Rate", role: .destructive) {
                                policyStore.removeRates(forRole: role)
                            }
                        }
                    }
                }
            } header: {
                Text("Roles and rates")
            } footer: {
                Text("A shift with a role is paid at that role's rate. A role without its own rate is paid at the All roles rate (the hourly wage above).")
            }
            .listRowBackground(PaydayColor.fieldBackground)
        }
    }

    @ViewBuilder
    private var payrollSection: some View {
        Section {
            wageRow

            if currentRateCents != nil {
                Button("Rate changed on…") { isShowingRateChange = true }
            }

            Picker("Workweek starts", selection: $workweekStartWeekday) {
                ForEach(1...7, id: \.self) { day in
                    Text(weekdaySymbols[day - 1]).tag(day)
                }
            }

            Toggle("Daily overtime after 8 hours", isOn: dailyOvertimeBinding)

            if let pending = policyStore.pendingCalendarPolicy(today: today) {
                // Never silent about the delay: a change that took effect
                // today would re-bucket days already worked and move the
                // overtime on them.
                Text("Takes effect \(Self.longDate(pending.effectiveFrom, in: pending.payrollTimeZone))")
                    .font(PaydayFont.footnote)
                    .foregroundStyle(PaydayColor.textSecondary)
            }

            // Where card tips are paid decides what the expected check is:
            // on the paycheck it carries a tips line; paid at close it is
            // gratuity + wages and there is no tips line to audit.
            Picker("Card tips are paid", selection: Bindable(preferencesStore).isCardTipsPaidAtClose) {
                Text("On my paycheck").tag(false)
                Text("At the end of my shift").tag(true)
            }
            Text("Choose 'at the end of my shift' if you cash out card tips nightly or they go to a pay card.")
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)

            // Jobs (PR E1). Reads "1 job" until a second job is added, and
            // with one job nothing else in the app changes.
            NavigationLink {
                JobsSettingsView()
            } label: {
                HStack {
                    Text("Jobs")
                        .foregroundStyle(PaydayColor.textPrimary)
                    Spacer()
                    Text(JobsSettingsView.countLabel(policyStore.policies))
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            }

            HStack {
                Text("Payroll time zone")
                    .foregroundStyle(PaydayColor.textPrimary)
                Spacer()
                Text(Self.zoneLabel(policyStore.payrollTimeZone))
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            .accessibilityElement(children: .combine)

            if policyStore.payrollTimeZone.identifier != TimeZone.current.identifier {
                Button("Change…") { isShowingZoneChange = true }
            }
        } header: {
            Text("Payroll")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your shifts are dated in the payroll time zone, so travelling never moves one into a different day or week.")
                Text("Overtime is an estimate: 1.5x after 40 hours in a workweek, and after 8 hours in a day when daily overtime is on. California, Alaska, Nevada and Colorado count it that way. No double time. Your state or employer may count it differently.")
                // Settings is the one place that discloses the estimate
                // (Tyler, 2026-11-08: no caption under the numbers). So it
                // must speak for a mixed history too: after "Rate changed
                // on…" the older shifts keep the assumed rate (Codex on
                // PR #170).
                if shiftCount > 0, policyStore.policies.hasOnlyAssumedRates {
                    Text("Wages are estimated from your current rate.")
                } else if shiftCount > 0, policyStore.policies.hasAssumedRates {
                    Text("Wages on shifts before your rate change are estimated.")
                }
            }
        }
        .listRowBackground(PaydayColor.fieldBackground)
        .confirmationDialog(
            "Change the payroll time zone to \(Self.zoneLabel(.current))?",
            isPresented: $isShowingZoneChange,
            titleVisibility: .visible
        ) {
            Button("Change Time Zone") {
                policyStore.applyCalendarChange(
                    workweekStartWeekday: workweekStartWeekday,
                    payrollTimeZone: .current,
                    today: today
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shifts you have already logged keep the zone they were dated in. Only shifts from the next workweek on use the new one.")
        }
    }

    /// On when the latest calendar policy (pending or in effect) has a daily
    /// threshold. A change queues a pending policy like the workweek picker,
    /// so the "Takes effect" line above shows for it too.
    private var dailyOvertimeBinding: Binding<Bool> {
        Binding(
            get: { policyStore.policies.latestCalendar?.dailyOvertimeThresholdMinutes != nil },
            set: { isOn in
                policyStore.applyCalendarChange(
                    workweekStartWeekday: workweekStartWeekday,
                    payrollTimeZone: policyStore.payrollTimeZone,
                    dailyOvertimeThresholdMinutes: isOn ? Self.dailyOvertimeThresholdMinutes : nil,
                    today: today
                )
            }
        )
    }

    /// 8 hours: the daily rule in California, Alaska, Nevada and Colorado.
    static let dailyOvertimeThresholdMinutes = 480

    private var wageRow: some View {
        HStack {
            Text("Hourly wage")
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer()
            ZStack(alignment: .trailing) {
                Text(Self.rateDisplay(currentRateCents))
                    .foregroundStyle(currentRateCents == nil ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                TextField("", text: $wageDigitsText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($isWageFieldFocused)
                    .opacity(0.01)
                    .frame(maxWidth: 90)
                    .accessibilityLabel("Hourly wage")
                    .accessibilityValue(Self.rateDisplay(currentRateCents))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isWageFieldFocused = true }
    }

    @ViewBuilder
    private func rateHistoryPrompt(rate: Int) -> some View {
        Section {
            // The same rate the row above shows, through the same function.
            // It was the one figure in this section `docs/METRICS.md`'s
            // sweep missed (now [ST-02]): a second spelling of the rate, and
            // a second chance for the two to disagree about a nil.
            Text("Has your rate always been \(Self.rateDisplay(rate))?")
                .foregroundStyle(PaydayColor.textPrimary)
            Button("Yes, since I started") {
                policyStore.confirmRateHistory()
            }
            Button("It changed on…") { isShowingRateChange = true }
        } footer: {
            Text("Payday only knows the rate you have set now, so wages on older shifts are estimated from it. Answering this once is the whole fix.")
        }
        .listRowBackground(PaydayColor.fieldBackground)
    }

    // MARK: Helpers

    static let maxWageDigits = 4 // caps at $99.99/hr

    /// The wage row's rendered value: the rate, or **"Not set" and never
    /// "$0.00"**.
    ///
    /// `docs/METRICS.md` [ST-01] recorded the old spelling as a contract
    /// breach in so many words: "The rendered placeholder '$0.00' is a money
    /// string shown for a nil value, which the contract (Section 4, rule 4)
    /// forbids for an `.unavailable` state." nil has always meant the wage
    /// feature is off, and a money screen printing "$0.00" is claiming a
    /// rate of zero on real worked hours. Both the row and
    /// `RateChangeSheet`'s field call this, so there is one spelling of the
    /// rule and not two.
    ///
    /// Not an `EarningsFigure`: that type's contract is a `MetricID` from the
    /// registry plus a label the completeness rules allow, and a rate is a
    /// policy INPUT with neither — [ST-01]'s MetricID column reads
    /// "presentation-only (policy input)". The rule it would have enforced
    /// here, "an unavailable read renders no currency", is enforced directly
    /// by this function's own return value.
    static func rateDisplay(_ cents: Int?) -> String {
        guard let cents else { return "Not set" }
        return Money.string(fromCents: cents)
    }

    /// The one digits-to-rate rule, shared by the "Hourly wage" row and the
    /// rate-change sheet so the two fields cannot disagree about what the
    /// user typed.
    ///
    /// Nil for an empty field AND for zero. `Int("0")` is 0, not nil, and a
    /// rate of zero is not a rate: nil has always meant "the wage feature is
    /// off" and the ledger then reports `.rateNotSet` rather than a
    /// fabricated `$0.00` on real worked hours. Returning nil here is what
    /// keeps "$0.00" off the screen, keeps `baseHourlyWageCents` (still read
    /// by the shipped 1.0 build, the widget and the Siri intent) from being
    /// set to 0, and keeps the rate-change sheet's Save button disabled.
    static func rateCents(fromDigits text: String) -> Int? {
        let filtered = String(text.filter(\.isNumber).prefix(maxWageDigits))
        guard let parsed = Int(filtered), parsed > 0 else { return nil }
        return parsed
    }

    private func load() {
        wageDigitsText = policyStore.currentHourlyRateCents.map(String.init) ?? ""
        workweekStartWeekday = policyStore.policies.latestCalendar?.workweekStartWeekday
            ?? Calendar.current.firstWeekday
    }

    /// "Monday, October 5" in the payroll zone, so the date the user reads is
    /// the date payroll means.
    static func longDate(_ day: CivilDay, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else {
            return day.iso
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(.current))
    }

    /// "New York" rather than "America/New_York": the identifier is a
    /// database key, not a place anybody says out loud.
    static func zoneLabel(_ zone: TimeZone) -> String {
        zone.localizedName(for: .generic, locale: .current)
            ?? zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? zone.identifier
    }
}

/// "Rate changed on…": one date, one rate, one new policy. Only shifts on or
/// after the date are repriced, and the weekly overtime threshold stays
/// continuous across the change.
private struct RateChangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentRateCents: Int?
    /// "Rate Change" for All roles; "Bar Rate" for a role.
    var title = "Rate Change"
    /// False for a role's first rate, which applies to every shift with
    /// that role (like the "Hourly wage" row) and so has no date; `onSave`
    /// then receives a nil day.
    var asksForDate = true
    let onSave: (Int, CivilDay?) -> Void

    @State private var effectiveFrom = Date.now
    @State private var digitsText = ""
    @FocusState private var isFieldFocused: Bool

    /// Nil for an empty field AND for zero, via the shared rule. Gating Save
    /// on `cents != nil` alone let a typed `0` through as a `.confirmed`
    /// $0.00/hr policy, because `Int("0")` is 0 and not nil. A dated change
    /// to zero cannot express "the wage feature is off" (a removal has no
    /// date), so the field simply has no value until a real rate is typed:
    /// Save stays disabled and the row reads "Not set".
    private var cents: Int? {
        PayrollSettingsSection.rateCents(fromDigits: digitsText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Hourly wage")
                            .foregroundStyle(PaydayColor.textPrimary)
                        Spacer()
                        ZStack(alignment: .trailing) {
                            // The same one rule as the wage row, through the
                            // same function: two spellings of "Not set" is
                            // two chances for one of them to become "$0.00".
                            Text(PayrollSettingsSection.rateDisplay(cents))
                                .foregroundStyle(cents == nil ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                                .monospacedDigit()
                                .accessibilityHidden(true)
                            TextField("", text: $digitsText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($isFieldFocused)
                                .opacity(0.01)
                                .frame(maxWidth: 90)
                                .accessibilityLabel("New hourly wage")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isFieldFocused = true }

                    if asksForDate {
                        DatePicker("First day at this rate", selection: $effectiveFrom, in: ...Date.now, displayedComponents: .date)
                    }
                } header: {
                    Text("New rate")
                } footer: {
                    if asksForDate {
                        Text("Shifts before this day keep the rate they were paid at. Nothing you have already logged changes.")
                    } else {
                        Text("Every shift with this role is paid at this rate.")
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)
            }
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let cents else { return }
                        guard asksForDate else {
                            onSave(cents, nil)
                            dismiss()
                            return
                        }
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = .current
                        let components = calendar.dateComponents([.year, .month, .day], from: effectiveFrom)
                        guard let day = CivilDay(
                            validating: components.year ?? 2026,
                            month: components.month ?? 1,
                            day: components.day ?? 1
                        ) else { return }
                        onSave(cents, day)
                        dismiss()
                    }
                    .disabled(cents == nil)
                }
            }
            .onAppear {
                digitsText = currentRateCents.map(String.init) ?? ""
            }
        }
        .presentationBackground(PaydayColor.background)
    }
}

/// The role a rate sheet is open for.
private struct RoleRateEdit: Identifiable {
    let role: String
    var id: String { role }
}
