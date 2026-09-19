import Foundation
import PaydayCore
import SwiftData

/// Where a shift row came from. The fold writes `migration`, the agent API
/// writes `api`, and a person logging a shift on this device writes `device`.
enum ShiftRecordSource: String, Codable, Sendable {
    case device
    case api
    case migration
}

/// One shift as one record.
///
/// The legacy representation splits a single closeout across a cash `TipEntry`
/// and a credit `TipEntry`, with the shift-level facts (hours, tip-out, sales,
/// receipt) living on whichever of the two `ShiftDetails` picked as canonical.
/// That shape is what `TipBreakdown`, `ShiftDays` and `ShiftDetails` exist to
/// reassemble on every read, and it is why a wage-only shift cannot be saved
/// at all (`ShiftWriter.insertShift` appends a row only for a non-zero amount,
/// so hours with no tips produce zero rows and the hours are dropped).
///
/// `ShiftRecord` is the read-authoritative local mirror of `public.shifts`.
/// **The device never derives one.** Every value here arrives either from a
/// person using this build or from the server's single SQL deriver, which
/// folds each legacy `tip_entries` write into the shift representation in the
/// same transaction. `public.tip_entries` stays the legacy write surface
/// indefinitely, so `TipEntry` is not going away and neither is the legacy
/// read leg.
///
/// CloudKit rules, copied verbatim from `TipEntry` because they are the reason
/// that model survived three schema changes: every attribute is optional or
/// defaulted, there is no `@Attribute(.unique)` and no `#Unique`, and enums are
/// optional raw strings behind a non-trapping accessor.
///
/// There is deliberately **no `@Relationship` to `TipEntry`**. Provenance is a
/// list of ids (`legacyEntryIDsRaw`), not a graph edge. An edge would make the
/// legacy table mutable from this side and would make rollback — dropping this
/// entity and reading `TipEntry` again — impossible.
@Model
final class ShiftRecord {
    var id: UUID = UUID()
    var workDate: Date = Date.now

    // Optional raw string rather than a defaulted enum, exactly like
    // TipEntry.shiftPeriodRaw: "never set" is a real state, and SwiftData's
    // lightweight migration fills a missing optional with nil cleanly where a
    // non-optional enum would crash casting nil.
    private var shiftPeriodRaw: String?

    var cashTipsCents: Int = 0
    var creditTipsCents: Int = 0

    /// Optional for the same reason as `TipEntry.tipOutCents`: "no tip-out
    /// logged" and "tipped out zero" are different facts.
    var tipOutCents: Int?
    var salesCents: Int?
    var hoursWorked: Double?
    var clockIn: Date?
    var clockOut: Date?
    var serverCount: Int?

    // The persisted receipt payload. Private because `receiptMetrics` is
    // ENCODE-ONLY (see below) and `applyEarnings` is the only writer that may
    // move money; a bare setter on the decoded value is what once inflated $80
    // to $122.
    private var receiptMetricsJSON: Data?

    var note: String?
    var recordedAt: Date?

    private var sourceRaw: String?

    /// Which legacy `TipEntry` ids this shift was folded from, as one
    /// canonical comma-joined string. See `canonicalLegacyEntryIDs`.
    var legacyEntryIDsRaw: String?

    /// Local mutation timestamp, used only to order offline writes. The
    /// server's `updated_at` stays authoritative once a write is accepted.
    ///
    /// **It is advanced by `touch()`, never by a property observer.** MEASURED
    /// on this toolchain (iOS 26 simulator, Swift 6): a `didSet` on a `@Model`
    /// stored property **never fires** — inserted or not, saved or not. A
    /// probe model counting its own `didSet` calls reports zero, and a
    /// `TipEntry` edited across a 50 ms sleep reports a `modifiedAt` delta of
    /// exactly 0.0.
    ///
    /// That matters because `clientUpdatedAt` is derived from this field
    /// (`PaydayRemoteModels.swift:206`) and `PaydaySyncState.changedIDs`
    /// compares it against the acknowledged value, so a record whose
    /// `modifiedAt` did not advance is reported as already synced and its edit
    /// is never pushed. Every writer of this record must therefore call
    /// `touch()`, which is what makes `ShiftCommands.perform` (S9) the right
    /// place to do it exactly once per save.
    var modifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        workDate: Date = .now,
        shiftPeriod: ShiftPeriod? = nil,
        cashTipsCents: Int = 0,
        creditTipsCents: Int = 0,
        tipOutCents: Int? = nil,
        salesCents: Int? = nil,
        hoursWorked: Double? = nil,
        clockIn: Date? = nil,
        clockOut: Date? = nil,
        serverCount: Int? = nil,
        receiptMetrics: ShiftReceiptMetrics? = nil,
        note: String? = nil,
        recordedAt: Date? = nil,
        source: ShiftRecordSource = .device,
        legacyEntryIDs: Set<UUID> = [],
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.workDate = workDate
        self.shiftPeriodRaw = shiftPeriod?.rawValue
        self.cashTipsCents = cashTipsCents
        self.creditTipsCents = creditTipsCents
        self.tipOutCents = tipOutCents
        self.salesCents = salesCents
        self.hoursWorked = hoursWorked
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.serverCount = serverCount
        self.receiptMetricsJSON = Self.encode(receiptMetrics)
        self.note = note
        self.recordedAt = recordedAt
        self.sourceRaw = source.rawValue
        self.legacyEntryIDsRaw = Self.canonicalLegacyEntryIDs(legacyEntryIDs)
        self.modifiedAt = modifiedAt
    }

    // MARK: - The mutation clock

    /// Advance the local mutation clock. Call it once per logical edit, after
    /// the edit, from the same place that saves.
    ///
    /// This exists because `didSet` on a `@Model` property is dead code (see
    /// `modifiedAt`). Skip it and the edit stays on this device forever: the
    /// push leg computes its upload set from `clientUpdatedAt`, which is this
    /// field, so an unchanged value means "already acknowledged".
    func touch(_ date: Date = .now) {
        modifiedAt = date
    }

    // MARK: - Enum accessors

    var shiftPeriod: ShiftPeriod? {
        get { shiftPeriodRaw.flatMap(ShiftPeriod.init(rawValue:)) }
        set { shiftPeriodRaw = newValue?.rawValue }
    }

    /// Non-trapping, and the `?? .device` fallback earns its keep on day one:
    /// the server's fold writes `'migration'`, a value no shipped build knows,
    /// and a future arm may write something newer still. An unrecognised
    /// source must read as an ordinary device row, never crash a launch.
    var source: ShiftRecordSource {
        get { Self.source(fromRaw: sourceRaw) }
        set { sourceRaw = newValue.rawValue }
    }

    /// The fallback as a pure function, so the `?? .device` branch is testable
    /// without a stored row carrying a value no shipped build can write.
    static func source(fromRaw raw: String?) -> ShiftRecordSource {
        raw.flatMap(ShiftRecordSource.init(rawValue:)) ?? .device
    }

    // MARK: - Provenance

    /// The legacy ids this shift was folded from.
    ///
    /// Stored as a canonical string so two writers produce byte-identical
    /// rows: de-duplicated, lowercased, sorted, comma-joined, and nil rather
    /// than `""` when empty. Byte-identical matters because the fold is
    /// idempotent by key — calling the deriver again on unchanged sources must
    /// produce the same row, and a set serialised in arrival order would make
    /// every re-fold look like a change.
    var legacyEntryIDs: Set<UUID> {
        get {
            guard let legacyEntryIDsRaw, !legacyEntryIDsRaw.isEmpty else { return [] }
            return Set(legacyEntryIDsRaw.split(separator: ",").compactMap {
                UUID(uuidString: String($0))
            })
        }
        set { legacyEntryIDsRaw = Self.canonicalLegacyEntryIDs(newValue) }
    }

    /// The one canonical spelling of a provenance list. nil when empty.
    static func canonicalLegacyEntryIDs(_ ids: some Sequence<UUID>) -> String? {
        let canonical = Set(ids)
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
        return canonical.isEmpty ? nil : canonical
    }

    // MARK: - Receipt metrics

    /// **Encode-only.** The setter encodes and mutates nothing else.
    ///
    /// Normalising v1 receipt data means moving money between `cashTipsCents`
    /// and `creditTipsCents`, and a property setter that mutates two other
    /// stored properties is order-dependent with nothing binding a call site's
    /// assignment order. Use `applyEarnings`, which is atomic over all of it.
    ///
    /// `design-lint.sh` fails the build on `.receiptMetrics =` outside this
    /// file for exactly that reason.
    var receiptMetrics: ShiftReceiptMetrics? {
        get { Self.decode(receiptMetricsJSON) }
        set {
            // `?? 0`, not `?? 2`. A MISSING key used to satisfy this
            // assert by defaulting to 2, while `ShiftReceiptMetrics` reads
            // the same missing key as `?? 1` and folds on it. One absent
            // field, two generations -- and the two readers then disagree by
            // exactly the gratuity (measured: 300c and 100c).
            //
            // No sanctioned writer produces that state: the SQL deriver
            // stamps after folding, and `applyEarnings` goes through
            // `normalizedToV2`, which does both and is idempotent. So this
            // makes an unreachable state UNREPRESENTABLE rather than fixing
            // a live bug. Do not "fix" the disagreement by relabelling a
            // payload downstream: without subtracting the folded gratuity
            // that double-counts the money permanently, which is the worse
            // direction and which `design-lint` refuses.
            // Clearing to nil stays legal -- that is how a payload is
            // removed. What is rejected is a PRESENT payload with an absent
            // version, which the old `?? 2` waved through.
            assert(
                Self.storesV2Earnings(newValue),
                "ShiftRecord stores v2 earnings only, and an ABSENT version is not v2. Use applyEarnings."
            )
            receiptMetricsJSON = Self.encode(newValue)
        }
    }

    /// The invariant the setter asserts, as a value rather than a trap.
    ///
    /// Extracted because an `assert` cannot be demonstrated without killing
    /// the test process -- and a guard nobody has watched fail is not a
    /// guard. `ShiftRecordV2InvariantTests` exercises this directly.
    ///
    /// Clearing to nil is legal; that is how a payload is removed. What is
    /// rejected is a PRESENT payload whose version is absent.
    static func storesV2Earnings(_ metrics: ShiftReceiptMetrics?) -> Bool {
        guard let metrics else { return true }
        return (metrics.earningsSchemaVersion ?? 0) >= 2
    }

    /// True when a payload is present but will not decode.
    ///
    /// Load-bearing, not diagnostic. `shifts.gratuity_fees_cents` is a
    /// generated column on the server, so a nil-metrics getter feeding
    /// `applyEarnings` would zero gratuity locally and then push that zero
    /// over the server's generated value. A record in this state is excluded
    /// from the sync push set and surfaced in Data health as a receipt that
    /// could not be read. It is never silently rewritten.
    var receiptPayloadIsUnreadable: Bool {
        receiptMetricsJSON != nil && Self.decode(receiptMetricsJSON) == nil
    }

    /// Installs a receipt payload verbatim, without decoding it.
    ///
    /// Two callers, both legitimate: the sync layer adopting the server's
    /// sanitised payload byte-for-byte (the server rewrites
    /// `earningsSchemaVersion` and rounds `gratuityFeesCents` so the payload
    /// and its generated column agree by construction — re-encoding a decoded
    /// copy here would be a second implementation of that rule), and the test
    /// that pins `receiptPayloadIsUnreadable`. It moves no money, which is
    /// what makes it safe next to the encode-only setter.
    func setRawReceiptPayload(_ payload: Data?) {
        receiptMetricsJSON = payload
    }

    /// The raw persisted payload, for the push leg's byte-identical comparison
    /// and for tests. Read-only on purpose.
    var rawReceiptPayload: Data? { receiptMetricsJSON }

    // MARK: - The one earnings writer

    /// The only writer of shift earnings, atomic over cash, credit and the
    /// receipt payload together.
    ///
    /// `metricsOwner` says which of the two amounts a v1 receipt's gratuity is
    /// folded into, because in the legacy shape the receipt lived on exactly
    /// one row and `TipBreakdown` normalises only that row. Passing the wrong
    /// owner moves real money: on the N4 shape (cash 5000, credit 2000,
    /// gratuity 4200) the credit owner gives cash 5000 / credit 0 and the cash
    /// owner gives cash 800 / credit 2000.
    ///
    /// Resolve `metricsOwner` with `ShiftDetails.metricsOwner(of:)?.kind`.
    /// That is the only spelling that agrees with the server's `metrics_rank`
    /// on a group holding two rows of one kind, which the agent API's
    /// `create_tip_entry` and `MigrationRunner.backfillShiftIDs` both
    /// produce without any data corruption.
    func applyEarnings(
        cashCents: Int,
        creditCents: Int,
        metrics: ShiftReceiptMetrics?,
        metricsOwner: TipKind
    ) {
        guard let metrics else {
            cashTipsCents = cashCents
            creditTipsCents = creditCents
            receiptMetrics = nil
            touch()
            return
        }
        let normalized = ShiftReceiptMetrics.normalizedToV2(
            cashCents: cashCents,
            creditCents: creditCents,
            metrics: metrics,
            owner: metricsOwner
        )
        cashTipsCents = normalized.cash
        creditTipsCents = normalized.credit
        receiptMetrics = normalized.metrics
        touch()
    }

    // MARK: - Derived money

    /// Voluntary tips plus employee gratuity, minus tip-out. The Swift twin of
    /// `shifts.non_wage_earnings_cents`, which is a generated column.
    /// Delegated to the ONE definition rather than spelling the formula a
    /// second time.
    ///
    /// `nonWageEarnings` was written out independently in five places --
    /// here, `EarningsComponents`, `TipBreakdown`, `LegacyShiftRow` and
    /// `StatsEngine`. Identical arithmetic in all five, which is precisely
    /// the hazard: they agree until one is edited, and then they disagree
    /// silently about a number the user is looking at.
    ///
    /// Reading the fields RAW is correct here and is the record's invariant:
    /// a `ShiftRecord` holds v2 earnings, so `cashTipsCents` and
    /// `creditTipsCents` are voluntary-only and the gratuity is a separate
    /// additive category. See `storesV2Earnings`.
    var nonWageEarningsCents: Int {
        EarningsComponents(
            voluntaryCashCents: cashTipsCents,
            voluntaryCreditCents: creditTipsCents,
            gratuityFeesCents: receiptMetrics?.employeeGratuityFeesCents ?? 0,
            tipOutCents: tipOutCents ?? 0
        ).nonWageEarningsCents
    }

    // MARK: - Payload coding

    private static func encode(_ metrics: ShiftReceiptMetrics?) -> Data? {
        guard let metrics, !metrics.isEmpty else { return nil }
        return try? JSONEncoder().encode(metrics)
    }

    private static func decode(_ payload: Data?) -> ShiftReceiptMetrics? {
        guard let payload else { return nil }
        return try? JSONDecoder().decode(ShiftReceiptMetrics.self, from: payload)
    }
}
