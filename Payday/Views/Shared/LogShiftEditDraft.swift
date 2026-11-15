import Foundation

/// What the Edit Shift sheet writes back onto its `ShiftRecord`, held in the
/// form it is stored.
///
/// Each value is kept after the rule its write applies -- a tip-out of 0 is
/// nil, an empty note is nil, a role is trimmed, the day is clamped to today
/// and taken at its start -- so two drafts are equal exactly when they would
/// write the same record. That equality is what lets `LogTipSheet` skip a
/// write nobody asked for: an untouched sheet's draft equals the one it
/// seeded, and writing it anyway would stamp a new `modifiedAt` and upload a
/// copy that can be older than the server's.
///
/// `apply(to:)` is the only writer, so a value cannot be written without also
/// being compared.
struct LogShiftEditDraft: Equatable {
    /// The sheet's fields in the form its controls hold them: 0 for an
    /// amount not entered, "" for no note.
    struct Fields {
        var cashCents: Int
        var creditCents: Int
        var receiptMetrics: ShiftReceiptMetrics?
        var date: Date
        var note: String
        var hoursWorked: Double?
        var tipOutCents: Int
        var tipShareInCents: Int
        var roleName: String?
        var jobName: String?
        var salesCents: Int
        var shiftPeriod: ShiftPeriod?
        var clockIn: Date?
        var clockOut: Date?
        var serverCount: Int?
    }

    let cashCents: Int
    let creditCents: Int
    let receiptMetrics: ShiftReceiptMetrics?
    let workDate: Date
    let note: String?
    let hoursWorked: Double?
    let tipOutCents: Int?
    let tipShareInCents: Int?
    let roleName: String?
    let jobName: String?
    let salesCents: Int?
    let shiftPeriod: ShiftPeriod?
    let clockIn: Date?
    let clockOut: Date?
    let serverCount: Int?

    init(_ fields: Fields) {
        cashCents = fields.cashCents
        creditCents = fields.creditCents
        receiptMetrics = fields.receiptMetrics
        workDate = Calendar.current.startOfDay(for: min(fields.date, .now))
        note = fields.note.isEmpty ? nil : fields.note
        hoursWorked = fields.hoursWorked
        tipOutCents = fields.tipOutCents > 0 ? fields.tipOutCents : nil
        tipShareInCents = fields.tipShareInCents > 0 ? fields.tipShareInCents : nil
        roleName = ShiftRole.normalized(fields.roleName)
        jobName = ShiftRole.normalized(fields.jobName)
        salesCents = fields.salesCents > 0 ? fields.salesCents : nil
        shiftPeriod = fields.shiftPeriod
        clockIn = fields.clockIn
        clockOut = fields.clockOut
        serverCount = fields.serverCount
    }

    /// Writes every value onto `record`. Call it inside
    /// `ShiftCommands.update`, which saves and stamps the record.
    func apply(to record: ShiftRecord) {
        // `applyEarnings`, not three assignments, and the lint caught me
        // doing it the naive way. Cash, credit and the payload have to move
        // in ONE step because a v1 receipt's gratuity is folded into one of
        // the two amounts, so setting them independently bypasses the
        // v1 -> v2 normalisation and moves real money: on the N4 shape
        // (cash 5000, credit 2000, gratuity 4200) the two owners differ by
        // cash 800 versus cash 5000.
        //
        // `.credit` is the owner, matching the legacy credit-owns-metadata
        // convention. Measured: it is INERT for anything a record actually
        // carries, because `normalizedToV2` returns its inputs unchanged once
        // `earningsSchemaVersion >= 2`, and a `ShiftRecord`'s payload is
        // normalised once at migration while new scans already write v2. It
        // is still the right choice if a v1 payload ever reaches here, which
        // is why it is not just left to chance.
        record.applyEarnings(
            cashCents: cashCents,
            creditCents: creditCents,
            metrics: receiptMetrics,
            metricsOwner: .credit
        )
        record.workDate = workDate
        record.note = note
        record.hoursWorked = hoursWorked
        record.tipOutCents = tipOutCents
        record.tipShareInCents = tipShareInCents
        record.roleName = roleName
        record.jobName = jobName
        record.salesCents = salesCents
        record.shiftPeriod = shiftPeriod
        record.clockIn = clockIn
        record.clockOut = clockOut
        record.serverCount = serverCount
    }
}

extension LogShiftEditDraft.Fields {
    /// The values the Edit Shift sheet opens with. The sheet seeds its state
    /// from this, so the draft of an untouched sheet is
    /// `LogShiftEditDraft(Fields(record:))`.
    init(record: ShiftRecord) {
        self.init(
            cashCents: record.cashTipsCents,
            creditCents: record.creditTipsCents,
            receiptMetrics: record.receiptMetrics,
            date: record.workDate,
            note: record.note ?? "",
            hoursWorked: record.hoursWorked,
            tipOutCents: record.tipOutCents ?? 0,
            tipShareInCents: record.tipShareInCents ?? 0,
            roleName: record.roleName,
            jobName: record.jobName,
            salesCents: record.salesCents ?? 0,
            shiftPeriod: record.shiftPeriod,
            clockIn: record.clockIn,
            clockOut: record.clockOut,
            serverCount: record.serverCount
        )
    }
}
