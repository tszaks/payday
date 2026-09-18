import Foundation

/// Which stored shape a reader takes its shifts from.
///
/// This type exists to move a decision out of reach. Every screen used to
/// make it: read the predicate, call one of two builders. That shape has now
/// failed twice in the same way — `PeriodsView`, `InsightsView`,
/// `PaydayPushScheduler`, `DeleteAccountSheet`, `CalendarView` and
/// `CSVExporter` each called a legacy-only builder with no switch at all,
/// while every parity gate stayed green because each surface was internally
/// consistent with whatever it happened to read. An enumeration of the
/// callers was short twice, at five and then at seven.
///
/// So callers no longer choose. A builder takes BOTH lists and resolves the
/// representation itself, which has three consequences worth stating plainly:
/// a half-switched screen is unrepresentable because the screen no longer
/// makes the choice; the choice exists in exactly one place per builder; and
/// adding the parameters made every existing call site a compile error, so
/// the COMPILER enumerated the work rather than a lint anyone had to write
/// correctly.
///
/// `automatic` is what app code uses and the only case app code should use.
/// The two explicit cases exist for the parity suites, which have to pin an
/// arm in order to compare the two against each other — without them,
/// resolving from global state inside the builder would make "do both
/// representations agree" an untestable question, and that question is the
/// whole point of the flip.
enum ShiftRepresentation {
    /// Resolved from `PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount`
    /// at the moment of the build.
    case automatic
    case legacy
    case records

    /// Whether to read the new representation. The ONE read of the predicate
    /// that every builder funnels through.
    @MainActor
    var usesRecords: Bool {
        switch self {
        case .automatic: PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount
        case .legacy: false
        case .records: true
        }
    }
}
