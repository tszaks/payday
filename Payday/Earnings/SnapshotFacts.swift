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
//    • `BreakdownRow.ledgerRows(_:)`, `.total(_:)`, `.lipText(_:)` and
//      `.hasBreakdown(_:)` — the hero drawer's itemization, bottom line and
//      collapsed lip, built from ONE `EarningsResult`. They EXIST and are
//      tested; **neither screen calls them yet.** Dashboard and Period
//      detail still compose the list by hand from their own arithmetic, and
//      Period detail still BACK-DERIVES its tip-out. The swap needs the hero
//      period's `EarningsResult`, which is the hero migration: groups 2.1
//      and 2.4, wave 1. This is the worked example to copy, not a closed
//      row.
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
//  the legacy rows: `LegacySnapshotBridge.snapshot(shifts:policies:...)`,
//  same engine, same types, and the user's OWN `PolicyStore.policies` — so
//  the rate history, the workweek history and the frozen payroll zone are
//  the store's. What the bridge does not carry is the `paychecks` and
//  `schedule` inputs `EarningsStore` supplies, so a caller that starts
//  asking `snapshot.payPeriod(_:)` has to wait for the swap. Every wave-0
//  consumer asks `day(_:)`, `range(_:)` or `valuation(_:)`, which read
//  neither. See the bridge's own header for the list.
//
//  **The three heroes are the open hole.** Dashboard's, Period detail's and
//  DayDetailSheet's hero figures are still composed by the screen: the
//  snapshot on their facts structs feeds the ROWS and the CHART, not the
//  number at the top. So `tipOutCents > 0 ? "You kept" : "Total"` is still
//  live on DashboardView.swift:570 and PeriodDetailView.swift:264, and
//  Period detail's tip-out is still `max(0, cash + credit + gratuity − net)`
//  rather than the ledger's. Groups 2.1, 2.2 and 2.4 own those.
//
//  **One workweek source, and it is `PolicyStore.policies`.** Wave 0's first
//  cut had four screens spelling this four ways — two reading
//  `schedule?.firstWeekday` (the pay-period GRID's weekday, which PR 3
//  severed from the workweek) and two reading `latestCalendarPolicy`, which
//  is `calendars.last` and therefore a QUEUED FUTURE policy. Set the two
//  Settings controls differently and Insights allocated overtime across
//  different weeks than Period detail did over the same days. All four now
//  hand the bridge the whole `CompensationPolicies` value and let the engine
//  do the effective dating. Never reintroduce a scalar weekday or a scalar
//  rate on a money path.
//
//  The corollary, and it bit immediately: moving only the ROWS onto the
//  policy puts them on a different week than a hero still computed by
//  `PeriodIncome`, which takes a scalar. So the two screens that have both
//  read the scalar from the SAME policy (`policies.calendar(on:)`, the
//  effective-dated lookup — never `latestCalendar`, which is `calendars.last`
//  and can be a queued FUTURE policy). Pinned by
//  `OneWorkweekPerScreenTests`: with the grid weekday set against the policy,
//  Period detail's hero read $500.00 while its rows read $550.00 over the
//  same five shifts. If you migrate half a screen, migrate its workweek
//  whole.
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
