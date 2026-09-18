import CryptoKit
import Foundation

/// A canonical, sorted, versioned fingerprint of every input that can change
/// any earnings result: shifts, paychecks, pay schedule, rate policies,
/// calendar policies, `asOf`, and `engineVersion`. Two devices holding the
/// same inputs compute the same `digest` regardless of the order their
/// stores return rows in, and regardless of whether any two rows share an id
/// (the sort keys below are total orders, so `sorted`'s unspecified
/// stability cannot leak into the digest). The `EarningsStore` skips a
/// rebuild when the digest and `asOf` are unchanged; the `SnapshotUploader` uses the digest to know
/// a snapshot describes the fully synced dataset (Design 3).
///
/// Sub-digests (`shiftsDigest`, `paychecksDigest`, `scheduleDigest`,
/// `policiesDigest`) let the UI and tests say *what* changed.
///
/// ## Canonical encoding (contract: `paydaycore-manifest-v1`)
///
/// This format is a contract. Changing any byte of it changes every stored
/// digest, so a change requires a new version prefix and a new pinned hex in
/// `InputManifestTests`. It is NOT produced by `JSONEncoder` (key order and
/// float formatting there are not promised to be stable).
///
/// Every section text is UTF-8:
///
/// ```
/// paydaycore-manifest-v1\n
/// <section lines joined by "\n">
/// ```
///
/// with no trailing newline. Each record is one line of `|`-separated fields
/// in the fixed order below. Because `|` and `\n` are structural, the two
/// free-text fields (`PayScheduleInput.frequency` and
/// `PayrollCalendarPolicy.payrollTimeZone.identifier`) must contain neither;
/// `init` throws `ValidationError.reservedCharacter` for such a value (via
/// `validate(shifts:schedule:calendars:)`, which callers may also run up
/// front), so an ambiguous encoding is never produced and never traps. Every
/// other field is a UUID, an ISO day, an enum raw value, or an integer, none
/// of which can contain them. A nil optional is `-`. Civil days are
/// `YYYY-MM-DD`. `recordedAt` is integer seconds since 1970 (rounded toward
/// zero); a `Date` whose seconds do not fit an `Int` (or is not finite) is
/// rejected by the same `validate`, because `ShiftInput` decodes
/// `recordedAt` from JSON as a plain `Double` and a corrupt payload must be a
/// reportable error rather than a trap. UUIDs are `uuidString` (uppercase).
/// Integers are plain base-10 with a leading `-` when negative.
///
/// Shifts, sorted by (`id.uuidString`, whole encoded line):
/// `S|id|workDay|period|recordedAt|voluntaryCashCents|voluntaryCreditCents|gratuityFeesCents|tipOutCents|minutesWorked`
///
/// Paychecks, sorted by (`id.uuidString`, whole encoded line):
/// `P|id|periodStart|periodEnd|paidTipsCents|grossPayCents|netPayCents|regularWagesCents|overtimeWagesCents|gratuityCents|taxesCents`
///
/// Schedule (one line, or `schedule|-` when nil):
/// `schedule|frequency|anchorPeriodEnd|payDelayDays|firstWeekday`
///
/// Policies: rate policies sorted by (`effectiveFrom`, `id.uuidString`, whole
/// encoded line), then calendar policies sorted the same way:
/// `R|id|effectiveFrom|hourlyRateCents|provenance`
/// `C|id|effectiveFrom|workweekStartWeekday|overtimeThresholdMinutes|overtimeMultiplierHundredths|payrollTimeZone.identifier`
///
/// The whole encoded line is the final tiebreak in every sort so each key is
/// a TOTAL order: `sorted` is not documented as stable in Swift, so two
/// records sharing an id (or a rate/calendar sharing `(effectiveFrom, id)`)
/// would otherwise land in an input-order-dependent order and move the digest.
/// Lexicographic order on the full line is a function of the multiset of lines
/// alone, and for records with distinct keys it is exactly the key order, so
/// this tiebreak never changes the encoding of a duplicate-free input.
///
/// Sub-digest = SHA-256 of `prefix + section lines`. An empty section is just
/// the prefix line (`"paydaycore-manifest-v1\n"`).
///
/// Full digest = SHA-256 of the full canonical text:
///
/// ```
/// paydaycore-manifest-v1\n
/// engine|<engineVersion>\n
/// asOf|<YYYY-MM-DD or ->\n
/// shifts|<count>\n
/// <shift lines...>
/// paychecks|<count>\n
/// <paycheck lines...>
/// <schedule line>\n
/// rates|<count>\n
/// <rate lines...>
/// calendars|<count>\n
/// <calendar lines...>
/// ```
///
/// again joined by `\n` with no trailing newline (the count line of an empty
/// section is followed directly by the next header). All hex is lowercase.
public struct InputManifest: Hashable, Codable, Sendable {
    /// Bump when the arithmetic changes in a way that should invalidate stored results.
    public static let currentEngineVersion = 1
    /// The version prefix of the canonical encoding.
    public static let formatVersion = "paydaycore-manifest-v1"

    /// An input that cannot be encoded: free text that would break the
    /// `|`/newline-delimited encoding, or a `Date` with no integer-seconds
    /// representation.
    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        /// `field` names the offending input (`"schedule.frequency"` or
        /// `"calendar.payrollTimeZone"`), `value` is the rejected text.
        case reservedCharacter(field: String, value: String)
        /// `shiftID`'s `recordedAt` is not finite, or its whole seconds since
        /// 1970 do not fit an `Int`. Only reachable from a decoded payload
        /// (`Date` is a `Double` in JSON), never from a real clock reading.
        case unrepresentableDate(shiftID: UUID, value: TimeInterval)

        public var description: String {
            switch self {
            case .reservedCharacter(let field, let value):
                return "InputManifest: \(field) may not contain '|' or a newline, got \(value.debugDescription)"
            case .unrepresentableDate(let shiftID, let value):
                return "InputManifest: shift \(shiftID.uuidString) recordedAt \(value) is not a representable number of seconds since 1970"
            }
        }
    }

    /// Rejects any free-text input containing `|` or `\n`, and any
    /// `recordedAt` with no integer-seconds representation. `init` runs this
    /// same check and rethrows, so calling it up front is optional; do so when
    /// you want to reject a payload before assembling the rest of the inputs.
    /// `shifts` defaults to empty so a caller checking only the free-text
    /// fields can keep calling `validate(schedule:calendars:)`.
    public static func validate(
        shifts: [ShiftInput] = [],
        schedule: PayScheduleInput?,
        calendars: [PayrollCalendarPolicy]
    ) throws {
        if let frequency = schedule?.frequency, Canonical.containsReservedCharacter(frequency) {
            throw ValidationError.reservedCharacter(field: "schedule.frequency", value: frequency)
        }
        for calendar in calendars where Canonical.containsReservedCharacter(calendar.payrollTimeZone.identifier) {
            throw ValidationError.reservedCharacter(field: "calendar.payrollTimeZone", value: calendar.payrollTimeZone.identifier)
        }
        for shift in shifts {
            guard let recordedAt = shift.recordedAt else { continue }
            if Canonical.wholeSeconds(recordedAt) == nil {
                throw ValidationError.unrepresentableDate(shiftID: shift.id, value: recordedAt.timeIntervalSince1970)
            }
        }
    }

    public let shiftsDigest: String
    public let paychecksDigest: String
    public let scheduleDigest: String
    public let policiesDigest: String
    /// SHA-256 of the full canonical text, lowercase hex.
    public let digest: String

    public let shiftCount: Int
    public let paycheckCount: Int
    public let ratePolicyCount: Int
    public let calendarPolicyCount: Int
    public let engineVersion: Int
    public let asOf: CivilDay?

    /// Throws `ValidationError.reservedCharacter` when a free-text input
    /// would break the canonical encoding. Refusing here rather than in a
    /// precondition matters because these inputs reach us from decoded JSON
    /// (fixtures today, synced payloads later), and a bad payload must be an
    /// error the caller can report, not a crash in the money path.
    public init(
        shifts: [ShiftInput],
        paychecks: [PaycheckInput] = [],
        schedule: PayScheduleInput? = nil,
        rates: [PayRatePolicy] = [],
        calendars: [PayrollCalendarPolicy] = [],
        asOf: CivilDay? = nil,
        engineVersion: Int = InputManifest.currentEngineVersion
    ) throws {
        try InputManifest.validate(shifts: shifts, schedule: schedule, calendars: calendars)
        let shiftLines = Canonical.shiftLines(shifts)
        let paycheckLines = Canonical.paycheckLines(paychecks)
        let scheduleLine = Canonical.scheduleLine(schedule)
        let rateLines = Canonical.rateLines(rates)
        let calendarLines = Canonical.calendarLines(calendars)

        shiftsDigest = Canonical.sha256Hex(Canonical.sectionText(shiftLines))
        paychecksDigest = Canonical.sha256Hex(Canonical.sectionText(paycheckLines))
        scheduleDigest = Canonical.sha256Hex(Canonical.sectionText([scheduleLine]))
        policiesDigest = Canonical.sha256Hex(Canonical.sectionText(rateLines + calendarLines))

        let full = Canonical.fullText(
            engineVersion: engineVersion, asOf: asOf,
            shiftLines: shiftLines, paycheckLines: paycheckLines, scheduleLine: scheduleLine,
            rateLines: rateLines, calendarLines: calendarLines
        )
        digest = Canonical.sha256Hex(full)

        shiftCount = shifts.count
        paycheckCount = paychecks.count
        ratePolicyCount = rates.count
        calendarPolicyCount = calendars.count
        self.engineVersion = engineVersion
        self.asOf = asOf
    }

    /// The exact text `digest` is computed over. Exposed so tests can pin it
    /// and so a Deno implementation can be checked byte for byte. Throws the
    /// same `ValidationError` as `init` rather than returning an ambiguous
    /// encoding.
    public static func canonicalText(
        shifts: [ShiftInput],
        paychecks: [PaycheckInput] = [],
        schedule: PayScheduleInput? = nil,
        rates: [PayRatePolicy] = [],
        calendars: [PayrollCalendarPolicy] = [],
        asOf: CivilDay? = nil,
        engineVersion: Int = InputManifest.currentEngineVersion
    ) throws -> String {
        try validate(shifts: shifts, schedule: schedule, calendars: calendars)
        return Canonical.fullText(
            engineVersion: engineVersion, asOf: asOf,
            shiftLines: Canonical.shiftLines(shifts),
            paycheckLines: Canonical.paycheckLines(paychecks),
            scheduleLine: Canonical.scheduleLine(schedule),
            rateLines: Canonical.rateLines(rates),
            calendarLines: Canonical.calendarLines(calendars)
        )
    }

    /// Lowercase hex SHA-256 of a UTF-8 string. Public so callers comparing
    /// against a server-side digest use the same bytes.
    public static func sha256Hex(_ text: String) -> String {
        Canonical.sha256Hex(text)
    }

    /// The name Design 2 gives what `SnapshotStamp` carries: "the manifest
    /// summary (digests + counts)".
    ///
    /// It is a typealias rather than a second struct because this type IS
    /// that summary already — it holds five digests, four counts,
    /// `engineVersion` and `asOf`, and not one byte of a shift, paycheck or
    /// policy. A separate summary struct would be a second copy of the same
    /// eleven fields, and the two could disagree about which digest belongs
    /// to which count.
    public typealias Summary = InputManifest

    /// This manifest as the stamp's summary. A no-op that documents the
    /// line above at the call site.
    public var summary: Summary { self }

    // MARK: - Canonical encoding

    enum Canonical {
        static func containsReservedCharacter(_ text: String) -> Bool {
            text.contains("|") || text.contains("\n")
        }

        /// Whole seconds since 1970, truncated toward zero, or nil when the
        /// date has no `Int` representation (NaN, infinity, or out of range).
        /// Total by construction: `Int(someDouble)` traps on those inputs, and
        /// this encoder must never trap even if `validate` was bypassed.
        static func wholeSeconds(_ date: Date) -> Int? {
            let seconds = date.timeIntervalSince1970.rounded(.towardZero)
            guard seconds.isFinite else { return nil }
            return Int(exactly: seconds)
        }

        static func sha256Hex(_ text: String) -> String {
            let digest = SHA256.hash(data: Data(text.utf8))
            return digest.map { byte in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0" + hex : hex
            }.joined()
        }

        static func sectionText(_ lines: [String]) -> String {
            InputManifest.formatVersion + "\n" + lines.joined(separator: "\n")
        }

        static func fullText(
            engineVersion: Int, asOf: CivilDay?,
            shiftLines: [String], paycheckLines: [String], scheduleLine: String,
            rateLines: [String], calendarLines: [String]
        ) -> String {
            var lines: [String] = []
            lines.append("engine|\(engineVersion)")
            lines.append("asOf|\(field(asOf))")
            lines.append("shifts|\(shiftLines.count)")
            lines.append(contentsOf: shiftLines)
            lines.append("paychecks|\(paycheckLines.count)")
            lines.append(contentsOf: paycheckLines)
            lines.append(scheduleLine)
            lines.append("rates|\(rateLines.count)")
            lines.append(contentsOf: rateLines)
            lines.append("calendars|\(calendarLines.count)")
            lines.append(contentsOf: calendarLines)
            return sectionText(lines)
        }

        static func shiftLines(_ shifts: [ShiftInput]) -> [String] {
            shifts
                .map { s -> (String, String) in
                    (s.id.uuidString, [
                        "S", s.id.uuidString, s.workDay.iso, field(s.period?.rawValue),
                        // nil here can only mean an unrepresentable date, which
                        // `validate` rejects before any line is built; encoding it
                        // as `-` keeps this function total instead of trapping.
                        field(s.recordedAt.flatMap { wholeSeconds($0) }),
                        String(s.voluntaryCashCents), String(s.voluntaryCreditCents),
                        String(s.gratuityFeesCents),
                        // CANONICALIZED to the engine's own interpretation.
                        // `EarningsComponents.tipOutCents` is a non-optional
                        // Int defaulting to 0, so the engine reads nil and 0
                        // as the same money. A digest that told them apart
                        // was a change-detector more sensitive than the
                        // computation it guards: it reported "changed" for
                        // two inputs that value identically, which is a false
                        // signal, and it made one shift digest differently
                        // depending on whether it was read through
                        // `ShiftInputAdapter` (nil vs 0 preserved off
                        // `ShiftRecord.tipOutCents`) or through
                        // `LegacySnapshotBridge` (always nil, because
                        // `TipBreakdown` had already summed both to 0).
                        //
                        // The VALUE still preserves nil vs 0 -- the record
                        // genuinely carries that fact and fidelity is kept.
                        // Only the digest collapses them, because only the
                        // digest is asking "would this change the answer".
                        //
                        // If a caller ever needs "was tip-out entered" as a
                        // fact, it gets its own explicit field. It is never
                        // smuggled through the nil/0 ambiguity of a money
                        // column.
                        String(s.tipOutCents ?? 0),
                        field(s.minutesWorked),
                    ].joined(separator: "|"))
                }
                .sorted { $0 < $1 }
                .map { $0.1 }
        }

        static func paycheckLines(_ paychecks: [PaycheckInput]) -> [String] {
            paychecks
                .map { p -> (String, String) in
                    (p.id.uuidString, [
                        "P", p.id.uuidString, p.periodStart.iso, p.periodEnd.iso, String(p.paidTipsCents),
                        field(p.grossPayCents), field(p.netPayCents), field(p.regularWagesCents),
                        field(p.overtimeWagesCents), field(p.gratuityCents), field(p.taxesCents),
                    ].joined(separator: "|"))
                }
                .sorted { $0 < $1 }
                .map { $0.1 }
        }

        static func scheduleLine(_ schedule: PayScheduleInput?) -> String {
            guard let s = schedule else { return "schedule|-" }
            return ["schedule", s.frequency, s.anchorPeriodEnd.iso, String(s.payDelayDays), field(s.firstWeekday)]
                .joined(separator: "|")
        }

        static func rateLines(_ rates: [PayRatePolicy]) -> [String] {
            rates
                .map { r -> (CivilDay, String, String) in
                    (r.effectiveFrom, r.id.uuidString,
                     ["R", r.id.uuidString, r.effectiveFrom.iso, String(r.hourlyRateCents), r.provenance.rawValue]
                         .joined(separator: "|"))
                }
                .sorted { $0 < $1 }
                .map { $0.2 }
        }

        static func calendarLines(_ calendars: [PayrollCalendarPolicy]) -> [String] {
            calendars
                .map { c -> (CivilDay, String, String) in
                    (c.effectiveFrom, c.id.uuidString, [
                        "C", c.id.uuidString, c.effectiveFrom.iso, String(c.workweekStartWeekday),
                        String(c.overtimeThresholdMinutes), String(c.overtimeMultiplierHundredths),
                        c.payrollTimeZone.identifier,
                    ].joined(separator: "|"))
                }
                .sorted { $0 < $1 }
                .map { $0.2 }
        }

        static func field(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        static func field(_ value: String?) -> String { value ?? "-" }
        static func field(_ value: CivilDay?) -> String { value?.iso ?? "-" }
    }
}
