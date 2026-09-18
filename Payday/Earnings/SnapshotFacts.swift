import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  THE PR 5 ADAPTER CONTRACT
//
//  Read this before migrating a screen. It is four rules. Wave 0 (the shared
//  components: ShiftDayRow, HeroBreakdownDrawer, NightlyEarningsChart,
//  ShiftContextMenu, UndoDeleteToast) implements them, so every wave 1 and
//  wave 2 screen has a worked example to copy instead of a shape to invent.
//
//  ── RULE 1. A Facts struct keeps only PRESENTATION. ──────────────────────
//
//  Presentation is: labels, dates, which period is selected, grid geometry,
//  drawer row ORDER, "is there a breakdown to show", sort order, whether a
//  day is in the displayed month. Those stay.
//
//  Money is not presentation. Every cents figure a Facts struct exposes must
//  have arrived from an `EarningsSnapshot` query or a `ShiftValuation`, and
//  the struct must not add, subtract, scale, or round any of them. If you
//  find yourself writing `a + b` where a and b are cents, the engine already
//  has a query that returns the sum — `snapshot.range(_:)`, `snapshot.day(_:)`,
//  `snapshot.payPeriod(_:)` — and the reason to use it is that `Σ days ==
//  range` is guaranteed there and merely hoped for here.
//
//  ── RULE 2. It takes an `EarningsSnapshot` plus its own presentational
//     inputs. Nothing else. ────────────────────────────────────────────────
//
//      init(snapshot: EarningsSnapshot?, period: PayPeriod, now: Date, ...)
//
//  NOT `[TipEntry]`. NOT `wageCentsPerHour`. NOT `firstWeekday`. NOT a
//  `TimeZone`. Those are inputs to the ENGINE, and a Facts struct that takes
//  them is a Facts struct that can compute — which is how the app came to
//  hold five different wage roundings. The snapshot already baked the rate,
//  the workweek, the frozen payroll zone and the `asOf` cutoff into its
//  `stamp`; asking for them again invites a second answer.
//
//  The snapshot is OPTIONAL because `EarningsStore` is `.loading` before its
//  first build and `.unavailable` when a fetch fails. A nil snapshot is not
//  an empty snapshot: see rule 4.
//
//  ── RULE 3. No `Key` struct. No `dataRevision`. Use `stamp`. ─────────────
//
//  Today every screen has a private `XFactsKey: Hashable` listing the inputs
//  it thinks can move a number, plus a `@State private var dataRevision = 0`
//  bumped on `ModelContext.didSave`. Both are DELETED.
//
//  They were a hand-maintained list of dependencies, and a hand-maintained
//  list is a list with something missing from it. `SnapshotStamp` is the
//  complete one, computed: `stamp.digest` is a SHA-256 over every input that
//  can change any result, including `asOf` and the engine version. Cache on
//  the pair (stamp, this screen's own presentational inputs):
//
//      private struct FactsCache { let stamp: SnapshotStamp; let selection: X; let facts: Facts }
//      if cache?.stamp == snapshot.stamp, cache?.selection == selection { reuse }
//
//  Conform your Facts struct to `SnapshotFacts` and the compiler makes you
//  carry the stamp, which is what makes two screens' disagreement diffable:
//  same stamp means same dataset, by construction.
//
//  ── RULE 4. Money never appears as arithmetic in a view, and a failed read
//     never renders $0. ────────────────────────────────────────────────────
//
//  Views render `EarningsFigure` (PaydayCore, `Copy/CompletenessCopy.swift`).
//  It carries the cents, the label the completeness rules allow, and the
//  caption. It has one deliberate sharp edge: `figure.text` is nil when the
//  engine could not answer, so a view CANNOT accidentally print "$0.00" for
//  "Payday couldn't read your shifts" — it has to reach for a placeholder.
//
//  The two rules `EarningsFigure` enforces, which every screen inherits:
//    • `.partial` never renders the word "Total". It reads "Known so far".
//    • `.unavailable` renders no currency text at all.
//
//  Use `CompletenessCopy.earnedIncomeLabel(_:tipOutCents:gratuityFeesCents:)`
//  rather than writing `tipOut > 0 ? "You kept" : "Total"` again. The
//  registry (`MetricID.allowedLabels`) is asserted against that function, so
//  a label it returns is a label `docs/METRICS.md` sanctioned.
//
//  ── WHAT WAVE 0 ALREADY DID FOR YOU ─────────────────────────────────────
//
//    • `ShiftDayRowFacts(valuation:...)` / `(snapshot:shiftID:...)` — a row's
//      amount, from the ledger's workweek allocation. Never a rate.
//    • `BreakdownRow.ledgerRows(_:)` and `.total(_:)` — the hero drawer's
//      itemization and its bottom line, built from ONE `EarningsResult`.
//      Dashboard and Period detail were each composing this list by hand
//      from their own arithmetic, and Period detail was BACK-DERIVING its
//      tip-out. Both now call the same function.
//    • `EarningsChartFacts(snapshot:range:asOf:)` — one engine query per
//      bar, so a bar is an answer and not a number that agrees with one.
//
//  ── WHAT IS NOT DONE, AND WILL BITE YOU ─────────────────────────────────
//
//  **Nothing writes `ShiftRecord` locally yet.** PR 2 slices S5-S8 are open,
//  so `EarningsStore`'s snapshot is EMPTY on a real device: the store reads
//  `FetchDescriptor<ShiftRecord>` and the only writers of that model today
//  are tests. A screen that switches to `earningsStore.snapshot` before S7
//  lands shows a person with four years of shifts an empty screen.
//
//  Until then, wave 0 feeds the shared components a REAL snapshot built from
//  the legacy rows: `LegacySnapshotBridge.snapshot(shifts:...)`, same engine,
//  same types, different input table. When S7 lands, wave 1's swap is one
//  line per screen and nothing below it changes. That is the whole point of
//  making the SHAPE snapshot-native now.
// ═══════════════════════════════════════════════════════════════════════════

/// What every PR 5 screen adapter is.
///
/// Conforming is cheap and it buys rule 3: the compiler will not let a Facts
/// struct exist without carrying the stamp it was computed from, so the
/// screen has no reason to keep a hand-written `Key`.
///
/// `stamp` is optional for exactly one case: facts computed with no snapshot
/// in hand (`EarningsStore.loading`). Those facts must render placeholders,
/// never zeros — a nil stamp is the signal that no dataset stands behind
/// them, the same signal `EarningsResult.empty(metric:)` carries with its nil
/// `manifestDigest`.
protocol SnapshotFacts {
    /// The identity of the dataset these facts were computed from.
    var stamp: SnapshotStamp? { get }
}

extension SnapshotFacts {
    /// True when no dataset stands behind these facts, so every figure on
    /// them must render as unavailable rather than as zero.
    var isUnbacked: Bool { stamp == nil }
}
