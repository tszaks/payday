import SwiftUI

/// Settings > Payroll: the rate, the rate's history, the workweek the
/// overtime threshold is counted over, and the payroll time zone those
/// civil days are measured in (PaydayCore Design 1).
///
/// It is a section rather than its own screen because these four facts are
/// read together: "what am I paid, since when, over which week, in which
/// zone" is one question. The estimate disclaimer is part of the section for
/// the same reason — the overtime rule this engine supports (1.5x past 40
/// hours in a workweek) is the common federal one, not a guarantee about
/// anybody's state or employer, and the number is labelled where it is
/// produced rather than in an About screen nobody opens.
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

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    private var today: CivilDay {
        CivilDay(.now, in: policyStore.payrollTimeZone)
    }

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
        }
        .onAppear(perform: load)
        .onChange(of: wageDigitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxWageDigits))
            if filtered != newValue { wageDigitsText = filtered }
            let cents = filtered.isEmpty ? nil : Int(filtered)
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
                policyStore.applyRateChange(hourlyRateCents: cents, effectiveFrom: day)
                preferencesStore.baseHourlyWageCents = policyStore.currentHourlyRateCents
                load()
            }
            .paydayAppearance()
        }
    }

    // MARK: Sections

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

            if let pending = policyStore.pendingCalendarPolicy(today: today) {
                // Never silent about the delay: a change that took effect
                // today would re-bucket days already worked and move the
                // overtime on them.
                Text("Takes effect \(Self.longDate(pending.effectiveFrom, in: pending.payrollTimeZone))")
                    .font(PaydayFont.footnote)
                    .foregroundStyle(PaydayColor.textSecondary)
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
                Text("Overtime is an estimate: 1.5x after 40 hours in a workweek. Your state or employer may count it differently.")
                if policyStore.policies.hasOnlyAssumedRates, shiftCount > 0 {
                    Text("Wages are estimated from your current rate.")
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

    private var wageRow: some View {
        HStack {
            Text("Hourly wage")
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer()
            ZStack(alignment: .trailing) {
                // "Not set", never "$0.00": nil has always meant the wage
                // feature is off, and a money screen that prints $0.00 is
                // claiming a rate of zero.
                Text(currentRateCents.map { Money.string(fromCents: $0) } ?? "Not set")
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
                    .accessibilityValue(currentRateCents.map { Money.string(fromCents: $0) } ?? "Not set")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isWageFieldFocused = true }
    }

    @ViewBuilder
    private func rateHistoryPrompt(rate: Int) -> some View {
        Section {
            Text("Has your rate always been \(Money.string(fromCents: rate))?")
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

    private static let maxWageDigits = 4 // caps at $99.99/hr

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
    let onSave: (Int, CivilDay) -> Void

    @State private var effectiveFrom = Date.now
    @State private var digitsText = ""
    @FocusState private var isFieldFocused: Bool

    private var cents: Int? {
        let filtered = String(digitsText.filter(\.isNumber).prefix(4))
        return filtered.isEmpty ? nil : Int(filtered)
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
                            Text(cents.map { Money.string(fromCents: $0) } ?? "$0.00")
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

                    DatePicker("First day at this rate", selection: $effectiveFrom, in: ...Date.now, displayedComponents: .date)
                } header: {
                    Text("New rate")
                } footer: {
                    Text("Shifts before this day keep the rate they were paid at. Nothing you have already logged changes.")
                }
                .listRowBackground(PaydayColor.fieldBackground)
            }
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle("Rate Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let cents else { return }
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
