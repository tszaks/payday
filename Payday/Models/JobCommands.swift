import Foundation
import PaydayCore
import SwiftData

/// The Settings > Jobs writes (PR E1). A job is a name tag on shifts and
/// paychecks (nil = the primary job), so renaming a job or changing which
/// job is primary has to rewrite those tags, and it does it here, in one
/// save, before the job list itself changes. If the save fails nothing is
/// rewritten and the list stays as it was.
@MainActor
enum JobCommands {
    /// How many shifts and paychecks carry one job's tag.
    struct Usage: Equatable {
        var shifts: Int
        var paychecks: Int
        var total: Int { shifts + paychecks }
    }

    static func usage(of job: JobPolicy, shifts: [ShiftRecord], paychecks: [PaycheckRecord]) -> Usage {
        // The primary's records carry no tag; it can never be deleted, so
        // it has no usage to report.
        guard !job.isPrimary else { return Usage(shifts: 0, paychecks: 0) }
        return Usage(
            shifts: shifts.filter { ShiftRoleList.matches($0.jobName, job.name) }.count,
            paychecks: paychecks.filter { ShiftRoleList.matches($0.jobName, job.name) }.count
        )
    }

    /// Adds a job. The first extra job also writes the primary entry, named
    /// `primaryName` (renamable later).
    static func add(name: String, schedule: PayScheduleInput?, primaryName: String = "Main job", policyStore: PolicyStore) {
        policyStore.apply(policyStore.policies.addingJob(
            id: UUID(), name: name, schedule: schedule, primaryName: primaryName, primaryID: UUID()))
    }

    /// Renames a job and the tag on every shift and paycheck it is on.
    static func rename(
        jobID: UUID,
        to newName: String,
        policyStore: PolicyStore,
        shifts: [ShiftRecord],
        paychecks: [PaycheckRecord],
        in context: ModelContext
    ) throws {
        let updated = policyStore.policies.renamingJob(id: jobID, to: newName)
        guard updated != policyStore.policies,
              let old = policyStore.policies.jobs.first(where: { $0.id == jobID }),
              let new = updated.jobs.first(where: { $0.id == jobID }) else { return }
        if !old.isPrimary {
            try retag(shifts: shifts, paychecks: paychecks, in: context) { tag in
                ShiftRoleList.matches(tag, old.name) ? new.name : tag
            }
        }
        policyStore.apply(updated)
    }

    /// Makes a job the primary. A nil tag always means the primary, so the
    /// old primary's records take its name and the new primary's lose theirs.
    static func makePrimary(
        jobID: UUID,
        policyStore: PolicyStore,
        shifts: [ShiftRecord],
        paychecks: [PaycheckRecord],
        in context: ModelContext
    ) throws {
        let policies = policyStore.policies
        guard let new = policies.jobs.first(where: { $0.id == jobID }), !new.isPrimary,
              let old = policies.primaryJob else { return }
        try retag(shifts: shifts, paychecks: paychecks, in: context) { tag in
            if tag == nil { return old.name }
            return ShiftRoleList.matches(tag, new.name) ? nil : tag
        }
        policyStore.apply(policies.makingPrimary(jobID: jobID))
    }

    /// Removes a job only when nothing carries its name. Returns the usage
    /// that refused it, or nil when it was removed.
    @discardableResult
    static func remove(
        jobID: UUID,
        policyStore: PolicyStore,
        shifts: [ShiftRecord],
        paychecks: [PaycheckRecord]
    ) -> Usage? {
        guard let job = policyStore.policies.jobs.first(where: { $0.id == jobID }), !job.isPrimary else { return nil }
        let usage = usage(of: job, shifts: shifts, paychecks: paychecks)
        guard usage.total == 0 else { return usage }
        policyStore.apply(policyStore.policies.removingJob(id: jobID))
        return nil
    }

    /// Rewrites the job tag on every record `map` changes, touching each so
    /// it uploads, in one atomic save. A shift that may not be mutated right
    /// now (an unconfirmed fold result, `ShiftCommands.mayMutate`) is left
    /// alone: it is a legacy night, and legacy rows carry no job.
    static func retag(
        shifts: [ShiftRecord],
        paychecks: [PaycheckRecord],
        in context: ModelContext,
        _ map: (String?) -> String?
    ) throws {
        try ShiftCommands.commit(in: context) {
            for shift in shifts where ShiftCommands.mayMutate(shift) {
                let next = ShiftRole.normalized(map(shift.jobName))
                guard next != shift.jobName else { continue }
                shift.jobName = next
                shift.touch()
            }
            for paycheck in paychecks {
                let next = ShiftRole.normalized(map(paycheck.jobName))
                guard next != paycheck.jobName else { continue }
                paycheck.jobName = next
                paycheck.touch()
            }
        }
    }
}
