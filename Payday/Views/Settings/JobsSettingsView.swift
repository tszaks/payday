import PaydayCore
import SwiftData
import SwiftUI

/// Settings > Payroll > Jobs (PR E1, Pillar 9). A job is a name: shifts and
/// paychecks carry it as a tag, nil for the primary. With one job (no list
/// stored) this screen is the only place jobs appear at all.
///
/// Each job keeps its own pay periods, payday reminder, wage and workweek
/// (E2b): tapping a job other than the primary opens its detail. The first
/// job stays the primary: switching the primary would rewrite every untagged
/// shift and upload settings and shifts as two server writes, which another
/// device could see half-done, so Make Primary is not offered.
struct JobsSettingsView: View {
    @Environment(PolicyStore.self) private var policyStore
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(\.modelContext) private var modelContext

    @Query private var shiftRecords: [ShiftRecord]
    @Query private var paycheckRecords: [PaycheckRecord]

    @State private var isAddingJob = false
    @State private var actionJob: JobPolicy?
    /// The job whose wage and schedule screen is open.
    @State private var detailJob: JobPolicy?
    @State private var renamingJob: JobPolicy?
    @State private var renameText = ""
    @State private var refusal: String?
    @State private var saveFailed = false

    private var jobs: [JobPolicy] { policyStore.policies.jobs }

    var body: some View {
        Form {
            Section {
                if jobs.isEmpty {
                    jobRow(name: "Your job", isPrimary: true)
                } else {
                    ForEach(jobs) { job in
                        Button {
                            actionJob = job
                        } label: {
                            jobRow(name: job.name, isPrimary: job.isPrimary)
                        }
                    }
                }
                Button("Add job") { isAddingJob = true }
            } footer: {
                Text("With two or more jobs, the log sheet and the paycheck sheet ask which job. Each job keeps its own pay periods and payday reminder.")
            }
            .listRowBackground(PaydayColor.fieldBackground)
        }
        .scrollContentBackground(.hidden)
        .background(PaydayColor.background)
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            actionJob?.name ?? "",
            isPresented: Binding(get: { actionJob != nil }, set: { if !$0 { actionJob = nil } }),
            titleVisibility: .visible,
            presenting: actionJob
        ) { job in
            if !job.isPrimary {
                Button("Wage and Schedule") { detailJob = job }
            }
            Button("Rename") {
                renameText = job.name
                renamingJob = job
            }
            if !job.isPrimary {
                Button("Delete Job", role: .destructive) { delete(job) }
            }
        }
        .alert(
            "Rename Job",
            isPresented: Binding(get: { renamingJob != nil }, set: { if !$0 { renamingJob = nil } }),
            presenting: renamingJob
        ) { job in
            TextField("Job name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                run { try JobCommands.rename(
                    jobID: job.id, to: renameText, policyStore: policyStore,
                    shifts: shiftRecords, paychecks: paycheckRecords, in: modelContext) }
            }
        } message: { _ in
            Text("Every shift and paycheck with this job moves to the new name.")
        }
        .alert(
            "Job Not Deleted",
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
        .alert("Couldn't Save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was changed. Try again.")
        }
        .navigationDestination(item: $detailJob) { job in
            JobDetailView(jobID: job.id)
        }
        .sheet(isPresented: $isAddingJob) {
            AddJobSheet(asksForPrimaryName: jobs.isEmpty, takenNames: jobs.map(\.name), primarySchedule: scheduleStore.schedule) { name, primaryName, schedule in
                JobCommands.add(
                    name: name,
                    schedule: schedule.map { Self.scheduleInput($0) },
                    primaryName: ShiftRole.normalized(primaryName) ?? "Main job",
                    policyStore: policyStore
                )
            }
            .paydayAppearance()
        }
    }

    private func jobRow(name: String, isPrimary: Bool) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer()
            if isPrimary {
                Text("Primary")
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func delete(_ job: JobPolicy) {
        guard let usage = JobCommands.remove(
            jobID: job.id, policyStore: policyStore, shifts: shiftRecords, paychecks: paycheckRecords)
        else { return }
        refusal = Self.refusalMessage(job: job.name, usage: usage)
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { saveFailed = true }
    }

    /// The picked date as the civil day the person SAW. The date picker and
    /// the midnight normalisation in `AddJobSheet` run in the device
    /// calendar, so the day is read back in that same zone. Reading it in
    /// the payroll zone moved November 7 at New York midnight to November 6
    /// in Los Angeles, and this screen has no editor to put it right.
    static func scheduleInput(_ schedule: PaySchedule, pickedIn zone: TimeZone = .current) -> PayScheduleInput {
        PayScheduleInput(
            frequency: schedule.frequency.rawValue,
            anchorPeriodEnd: CivilDay(schedule.anchorPeriodEnd, in: zone),
            payDelayDays: schedule.resolvedPayDelayDays,
            firstWeekday: schedule.firstWeekday
        )
    }

    /// "Cafe is on 3 shifts and 1 paycheck. Move them to another job first."
    static func refusalMessage(job: String, usage: JobCommands.Usage) -> String {
        var parts: [String] = []
        if usage.shifts > 0 { parts.append(usage.shifts == 1 ? "1 shift" : "\(usage.shifts) shifts") }
        if usage.paychecks > 0 { parts.append(usage.paychecks == 1 ? "1 paycheck" : "\(usage.paychecks) paychecks") }
        return "\(job) is on \(parts.joined(separator: " and ")). Move them to another job first."
    }

    /// Whether `name` collides with a job that exists (trimmed,
    /// case-insensitive), or with `primaryName`, the name the current job
    /// gets when this add creates the list (nil once a list exists). The add
    /// sheet refuses such a name up front, because `addingJob` would change
    /// nothing and a sheet that closes on nothing looks like a lost job.
    static func nameIsTaken(_ name: String, existing: [String], primaryName: String?) -> Bool {
        guard let key = ShiftRole.key(name) else { return false }
        return existing.contains { ShiftRole.key($0) == key } || ShiftRole.key(primaryName) == key
    }

    /// The Settings > Payroll row's trailing text: "1 job" until a second
    /// job is added.
    static func countLabel(_ policies: CompensationPolicies) -> String {
        let count = max(1, policies.jobs.count)
        return count == 1 ? "1 job" : "\(count) jobs"
    }
}

/// Name, and an optional pay schedule of the job's own (default: same as
/// the primary). The first extra job also names the job the person already
/// has, because one job is stored as no list.
private struct AddJobSheet: View {
    @Environment(\.dismiss) private var dismiss

    let asksForPrimaryName: Bool
    /// Names already in the list, so a duplicate is refused before Save.
    let takenNames: [String]
    let primarySchedule: PaySchedule?
    let onSave: (_ name: String, _ primaryName: String, _ schedule: PaySchedule?) -> Void

    @State private var name = ""
    @State private var primaryName = ""
    /// Nil = same schedule as the primary job.
    @State private var frequency: PayFrequency?
    @State private var anchorPeriodEnd = Date.now

    private var nameIsTaken: Bool {
        JobsSettingsView.nameIsTaken(
            name, existing: takenNames,
            primaryName: asksForPrimaryName ? (ShiftRole.normalized(primaryName) ?? "Main job") : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job name", text: $name)
                        .textInputAutocapitalization(.words)
                    if asksForPrimaryName {
                        TextField("Your current job (Main job)", text: $primaryName)
                            .textInputAutocapitalization(.words)
                    }
                } footer: {
                    if nameIsTaken {
                        Text("A job with this name already exists.")
                    } else if asksForPrimaryName {
                        Text("Your current job stays the primary job. Every shift you have logged stays on it.")
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section {
                    Picker("Pay schedule", selection: $frequency) {
                        Text("Same as primary").tag(PayFrequency?.none)
                        ForEach(PayFrequency.allCases) { frequency in
                            Text(frequency.displayName).tag(PayFrequency?.some(frequency))
                        }
                    }
                    if frequency != nil {
                        DatePicker("Last day of a pay period", selection: $anchorPeriodEnd, displayedComponents: .date)
                    }
                } footer: {
                    Text("This job's pay periods and payday reminder follow this schedule.")
                }
                .listRowBackground(PaydayColor.fieldBackground)
            }
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle("Add Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let schedule = frequency.map {
                            PaySchedule(
                                frequency: $0,
                                anchorPeriodEnd: Calendar.current.startOfDay(for: anchorPeriodEnd),
                                payDelayDays: primarySchedule?.payDelayDays,
                                firstWeekday: primarySchedule?.firstWeekday
                            )
                        }
                        onSave(name, primaryName, schedule)
                        dismiss()
                    }
                    .disabled(ShiftRole.normalized(name) == nil || nameIsTaken)
                }
            }
        }
    }
}

/// One job's own pay facts (E2b): hourly wage, workweek start, daily
/// overtime and pay schedule. The same controls as Settings > Payroll, but
/// every write goes through a `PolicyStore` helper that takes this job's tag
/// and never touches the primary's policies. A new job starts on a copy of
/// the primary's calendar and with no wage ("Not set"): a different employer
/// is a different wage.
struct JobDetailView: View {
    @Environment(PolicyStore.self) private var policyStore
    @Environment(PayScheduleStore.self) private var scheduleStore

    let jobID: UUID

    @State private var wageDigitsText = ""
    @FocusState private var isWageFieldFocused: Bool
    @State private var workweekStartWeekday = 1
    @State private var hasLoaded = false

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    private var job: JobPolicy? { policyStore.policies.jobs.first { $0.id == jobID } }
    private var tag: String? { job?.tag }
    private var jobPolicies: CompensationPolicies { policyStore.policies.policies(forJob: tag) }
    private var zone: TimeZone { policyStore.payrollTimeZone(forJob: tag) }
    private var today: CivilDay { CivilDay(.now, in: zone) }
    private var rateCents: Int? { policyStore.currentHourlyRateCents(forJob: tag) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Hourly wage")
                        .foregroundStyle(PaydayColor.textPrimary)
                    Spacer()
                    ZStack(alignment: .trailing) {
                        Text(PayrollSettingsSection.rateDisplay(rateCents))
                            .foregroundStyle(rateCents == nil ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                            .monospacedDigit()
                            .accessibilityHidden(true)
                        TextField("", text: $wageDigitsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isWageFieldFocused)
                            .opacity(0.01)
                            .frame(maxWidth: 90)
                            .accessibilityLabel("Hourly wage")
                            .accessibilityValue(PayrollSettingsSection.rateDisplay(rateCents))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { isWageFieldFocused = true }

                Picker("Workweek starts", selection: $workweekStartWeekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(weekdaySymbols[day - 1]).tag(day)
                    }
                }

                Toggle("Daily overtime after 8 hours", isOn: dailyOvertimeBinding)

                if let pending = policyStore.pendingCalendarPolicy(today: today, job: tag) {
                    Text("Takes effect \(PayrollSettingsSection.longDate(pending.effectiveFrom, in: pending.payrollTimeZone))")
                        .font(PaydayFont.footnote)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
            } footer: {
                Text("This job's shifts are paid at this wage. With no wage set, their wages read as not set.")
            }
            .listRowBackground(PaydayColor.fieldBackground)

            Section {
                Picker("Pay schedule", selection: frequencyBinding) {
                    Text("Same as primary").tag(PayFrequency?.none)
                    ForEach(PayFrequency.allCases) { frequency in
                        Text(frequency.displayName).tag(PayFrequency?.some(frequency))
                    }
                }
                if job?.schedule != nil {
                    DatePicker("Last day of a pay period", selection: anchorBinding, displayedComponents: .date)
                }
            } footer: {
                Text("This job's pay periods and payday reminder follow this schedule.")
            }
            .listRowBackground(PaydayColor.fieldBackground)
        }
        .scrollContentBackground(.hidden)
        .background(PaydayColor.background)
        .navigationTitle(job?.name ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: wageDigitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(PayrollSettingsSection.maxWageDigits))
            if filtered != newValue { wageDigitsText = filtered }
            let cents = PayrollSettingsSection.rateCents(fromDigits: filtered)
            // Opening the screen writes the field; that is not an edit.
            guard hasLoaded, tag != nil, cents != rateCents else { return }
            policyStore.applyRateEdit(hourlyRateCents: cents, job: tag)
        }
        .onChange(of: workweekStartWeekday) { oldValue, newValue in
            guard hasLoaded, oldValue != newValue, tag != nil else { return }
            policyStore.applyCalendarChange(
                workweekStartWeekday: newValue, payrollTimeZone: zone, today: today, job: tag)
        }
    }

    private var dailyOvertimeBinding: Binding<Bool> {
        Binding(
            get: { jobPolicies.latestCalendar?.dailyOvertimeThresholdMinutes != nil },
            set: { isOn in
                guard tag != nil else { return }
                policyStore.applyCalendarChange(
                    workweekStartWeekday: workweekStartWeekday,
                    payrollTimeZone: zone,
                    dailyOvertimeThresholdMinutes: isOn ? PayrollSettingsSection.dailyOvertimeThresholdMinutes : nil,
                    today: today,
                    job: tag
                )
            }
        )
    }

    private var frequencyBinding: Binding<PayFrequency?> {
        Binding(
            get: { job?.schedule.flatMap { PayFrequency(rawValue: $0.frequency) } },
            set: { frequency in
                guard let frequency else {
                    policyStore.applyJobSchedule(nil, jobID: jobID)
                    return
                }
                let primary = scheduleStore.schedule
                let anchor = job?.schedule?.anchorPeriodEnd.date(in: .current)
                    ?? Calendar.current.startOfDay(for: .now)
                let schedule = PaySchedule(
                    frequency: frequency, anchorPeriodEnd: anchor,
                    payDelayDays: job?.schedule?.payDelayDays ?? primary?.payDelayDays,
                    firstWeekday: primary?.firstWeekday)
                policyStore.applyJobSchedule(JobsSettingsView.scheduleInput(schedule), jobID: jobID)
            }
        )
    }

    private var anchorBinding: Binding<Date> {
        Binding(
            get: { job?.schedule?.anchorPeriodEnd.date(in: .current) ?? .now },
            set: { date in
                guard var input = job?.schedule else { return }
                input.anchorPeriodEnd = CivilDay(Calendar.current.startOfDay(for: date), in: .current)
                policyStore.applyJobSchedule(input, jobID: jobID)
            }
        )
    }

    private func load() {
        wageDigitsText = rateCents.map(String.init) ?? ""
        workweekStartWeekday = jobPolicies.latestCalendar?.workweekStartWeekday
            ?? policyStore.policies.latestCalendar?.workweekStartWeekday
            ?? Calendar.current.firstWeekday
        DispatchQueue.main.async { hasLoaded = true }
    }
}
