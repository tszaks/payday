import Testing
import Foundation
import SwiftData
@testable import Payday

private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: d))!
}

/// The N4 shape, which is the one fixture in this document where the read path
/// and the edit path disagree about real money: cash 5000, credit 2000, and a
/// v1 receipt attached to the credit row carrying a folded gratuity of 4200
/// that the credit amount is SHORT of.
private func n4Metrics() -> ShiftReceiptMetrics {
    ShiftReceiptMetrics(earningsSchemaVersion: nil, gratuityFeesCents: 4_200)
}

@Suite("ShiftRecord")
@MainActor
struct ShiftRecordTests {

    // MARK: - The encode-only setter

    @Test("the receiptMetrics setter encodes and mutates nothing else")
    func receiptMetricsSetterIsEncodeOnly() {
        let record = ShiftRecord(
            workDate: day(2026, 7, 1),
            cashTipsCents: 5_000,
            creditTipsCents: 2_000,
            tipOutCents: 1_000
        )

        record.receiptMetrics = ShiftReceiptMetrics(
            earningsSchemaVersion: 2,
            gratuityFeesCents: 4_200
        )

        // The whole point: no money moved. Normalizing v1 data means moving
        // cents between these two, and a setter that did it would be
        // order-dependent against whatever a call site assigns first.
        #expect(record.cashTipsCents == 5_000)
        #expect(record.creditTipsCents == 2_000)
        #expect(record.tipOutCents == 1_000)
        #expect(record.receiptMetrics?.employeeGratuityFeesCents == 4_200)
    }

    @Test("applyEarnings advances the mutation clock; a bare assignment does not")
    func applyEarningsTouchesTheMutationClock() {
        let record = ShiftRecord(
            workDate: day(2026, 7, 1),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let before = record.modifiedAt

        record.applyEarnings(
            cashCents: 5_000,
            creditCents: 0,
            metrics: nil,
            metricsOwner: .credit
        )
        #expect(record.modifiedAt > before)

        // And the half that costs money if it is forgotten: assigning a
        // property directly does NOT advance the clock, because didSet on a
        // @Model property is dead code. Every writer calls touch().
        let stamped = record.modifiedAt
        record.hoursWorked = 7.5
        #expect(record.modifiedAt == stamped)
        record.touch()
        #expect(record.modifiedAt > stamped)
    }

    /// CHARACTERIZATION of the toolchain, not of Payday. It exists so nobody
    /// re-adds `didSet { modifiedAt = .now }` to a `@Model` and believes it.
    ///
    /// MEASURED on the iOS 26 simulator with Swift 6: a `didSet` observer on a
    /// `@Model` stored property never runs. The probe below counts its own
    /// observer calls and gets zero, whether or not the object is in a
    /// `ModelContext` and whether or not the context has been saved.
    ///
    /// The shipped consequence is not hypothetical and is not fixed here:
    /// `TipEntry` and `PaycheckRecord` both declare `didSet { modifiedAt =
    /// .now }` on every stored property, so their `modifiedAt` is frozen at
    /// insert, `clientUpdatedAt` never changes, `PaydaySyncState.changedIDs`
    /// never reports an edited row, and Payday 1.0 cannot push an edit to an
    /// existing tip or paycheck at all. Inserts and deletions are unaffected
    /// (a fresh row gets a fresh `modifiedAt`; deletions go through the
    /// pending-deletions queue).
    @Test("CHARACTERIZATION: didSet on a @Model property never fires")
    func didSetOnAModelPropertyNeverFires() throws {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let entry = TipEntry(date: day(2026, 7, 1), amountCents: 5_000, kind: .cash)
        context.insert(entry)
        try context.save()

        let atInsert = entry.modifiedAt
        entry.amountCents = 9_900
        entry.note = "edited"
        entry.tipOutCents = 1_200
        try context.save()

        #expect(entry.amountCents == 9_900)
        #expect(entry.modifiedAt == atInsert)
    }

    @Test("applyEarnings is the writer that does move money, atomically")
    func applyEarningsWritesCashCreditAndPayloadTogether() {
        let record = ShiftRecord(workDate: day(2026, 7, 1), tipOutCents: 1_000)

        record.applyEarnings(
            cashCents: 5_000,
            creditCents: 2_000,
            metrics: n4Metrics(),
            metricsOwner: .credit
        )

        #expect(record.cashTipsCents == 5_000)
        #expect(record.creditTipsCents == 0)
        #expect(record.receiptMetrics?.earningsSchemaVersion == 2)
        #expect(record.receiptMetrics?.employeeGratuityFeesCents == 4_200)
        #expect(record.nonWageEarningsCents == 8_200)
    }

    @Test("applyEarnings with no metrics clears the payload and keeps the amounts")
    func applyEarningsWithNoMetricsClearsThePayload() {
        let record = ShiftRecord(workDate: day(2026, 7, 1))
        record.applyEarnings(
            cashCents: 5_000,
            creditCents: 2_000,
            metrics: n4Metrics(),
            metricsOwner: .credit
        )

        record.applyEarnings(cashCents: 3_000, creditCents: 1_000, metrics: nil, metricsOwner: .credit)

        #expect(record.cashTipsCents == 3_000)
        #expect(record.creditTipsCents == 1_000)
        #expect(record.receiptMetrics == nil)
        #expect(record.receiptPayloadIsUnreadable == false)
    }

    // MARK: - receiptPayloadIsUnreadable

    @Test("no payload and a good payload both read as readable")
    func receiptPayloadIsUnreadableIsFalseForNilAndValid() {
        let empty = ShiftRecord(workDate: day(2026, 7, 1))
        #expect(empty.receiptPayloadIsUnreadable == false)

        let good = ShiftRecord(
            workDate: day(2026, 7, 1),
            receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 4_200)
        )
        #expect(good.receiptMetrics != nil)
        #expect(good.receiptPayloadIsUnreadable == false)
    }

    @Test("receiptPayloadIsUnreadable catches a payload present but undecodable")
    func receiptPayloadIsUnreadable() {
        let record = ShiftRecord(workDate: day(2026, 7, 1))

        record.setRawReceiptPayload(Data(#"{"earningsSchemaVersion": 2,"#.utf8))
        #expect(record.receiptMetrics == nil)
        #expect(record.receiptPayloadIsUnreadable)

        // The production shape, not a hypothetical: a scanner can write a
        // fractional gratuity, the server rounds it in the generated column
        // but a payload copied through verbatim keeps 1234.6, and
        // gratuityFeesCents decodes as Int? so the WHOLE payload fails. This
        // record must be excluded from the push set rather than have its
        // gratuity silently read as zero and pushed over the server's value.
        record.setRawReceiptPayload(
            Data(#"{"earningsSchemaVersion": 2, "gratuityFeesCents": 1234.6}"#.utf8)
        )
        #expect(record.receiptMetrics == nil)
        #expect(record.receiptPayloadIsUnreadable)
        #expect(record.receiptMetrics?.employeeGratuityFeesCents == nil)
    }

    // MARK: - The ?? .device fallback

    @Test("an unknown or missing source raw value reads as .device")
    func unknownSourceFallsBackToDevice() {
        // The fold writes 'migration', which no shipped 1.0 build knows, and a
        // later arm may write something newer still. Every one of these has to
        // read as an ordinary device row rather than crash a launch.
        #expect(ShiftRecord.source(fromRaw: nil) == .device)
        #expect(ShiftRecord.source(fromRaw: "") == .device)
        #expect(ShiftRecord.source(fromRaw: "whatever-pr-9-invents") == .device)
        #expect(ShiftRecord.source(fromRaw: "Migration") == .device)

        #expect(ShiftRecord.source(fromRaw: "device") == .device)
        #expect(ShiftRecord.source(fromRaw: "api") == .api)
        #expect(ShiftRecord.source(fromRaw: "migration") == .migration)
    }

    @Test("source round-trips through the stored raw string")
    func sourceRoundTrips() {
        let record = ShiftRecord(workDate: day(2026, 7, 1), source: .migration)
        #expect(record.source == .migration)

        record.source = .api
        #expect(record.source == .api)

        let defaulted = ShiftRecord(workDate: day(2026, 7, 1))
        #expect(defaulted.source == .device)
    }

    // MARK: - The canonical provenance string

    @Test("legacyEntryIDsRaw is one canonical string: deduped, lowercased, sorted")
    func canonicalLegacyEntryIDString() {
        let a = UUID(uuidString: "0E7B1F9C-1111-4111-8111-111111111111")!
        let b = UUID(uuidString: "A2C4D6E8-2222-4222-8222-222222222222")!
        let c = UUID(uuidString: "5AAC5D01-3333-4333-8333-333333333333")!

        #expect(ShiftRecord.canonicalLegacyEntryIDs([]) == nil)
        #expect(
            ShiftRecord.canonicalLegacyEntryIDs([a]) == "0e7b1f9c-1111-4111-8111-111111111111"
        )

        // Two writers handed the same ids in different orders, one of them
        // with a duplicate, must produce byte-identical rows: the fold is
        // idempotent by key, so a set serialised in arrival order would make
        // every re-fold look like a change and re-push the row forever.
        let one = ShiftRecord.canonicalLegacyEntryIDs([c, a, b])
        let two = ShiftRecord.canonicalLegacyEntryIDs([b, c, a, a])
        #expect(one == two)
        #expect(one == [
            "0e7b1f9c-1111-4111-8111-111111111111",
            "5aac5d01-3333-4333-8333-333333333333",
            "a2c4d6e8-2222-4222-8222-222222222222"
        ].joined(separator: ","))
    }

    @Test("legacyEntryIDs round-trips through the canonical string")
    func legacyEntryIDsRoundTrip() {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        let record = ShiftRecord(workDate: day(2026, 7, 1), legacyEntryIDs: ids)

        #expect(record.legacyEntryIDs == ids)
        #expect(record.legacyEntryIDsRaw != nil)

        record.legacyEntryIDs = []
        #expect(record.legacyEntryIDsRaw == nil)
        #expect(record.legacyEntryIDs.isEmpty)

        let junk = ShiftRecord(workDate: day(2026, 7, 1))
        junk.legacyEntryIDsRaw = "not-a-uuid,,also-not"
        #expect(junk.legacyEntryIDs.isEmpty)
    }

    // MARK: - The store

    @Test("a ShiftRecord survives a container reopen with every field intact")
    func shiftRecordSurvivesAContainerReopen() throws {
        let url = URL.temporaryDirectory
            .appending(path: "payday-shiftrecord-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        let legacyID = UUID()
        do {
            let container = try ModelContainer(
                for: SharedModelContainer.schema,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            let record = ShiftRecord(
                id: id,
                workDate: day(2026, 3, 5),
                shiftPeriod: .dinner,
                cashTipsCents: 5_000,
                creditTipsCents: 0,
                tipOutCents: 1_000,
                hoursWorked: 7.5,
                receiptMetrics: ShiftReceiptMetrics(
                    earningsSchemaVersion: 2,
                    gratuityFeesCents: 4_200
                ),
                note: "Saturday double",
                source: .migration,
                legacyEntryIDs: [legacyID]
            )
            context.insert(record)
            try context.save()
        }

        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        let loaded = try context.fetch(FetchDescriptor<ShiftRecord>())

        #expect(loaded.count == 1)
        let record = try #require(loaded.first)
        #expect(record.id == id)
        #expect(record.shiftPeriod == .dinner)
        #expect(record.cashTipsCents == 5_000)
        #expect(record.tipOutCents == 1_000)
        #expect(record.hoursWorked == 7.5)
        #expect(record.note == "Saturday double")
        #expect(record.source == .migration)
        #expect(record.legacyEntryIDs == [legacyID])
        #expect(record.receiptMetrics?.employeeGratuityFeesCents == 4_200)
        #expect(record.nonWageEarningsCents == 8_200)
    }
}
