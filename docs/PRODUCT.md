# Payday Product Vision: The World's Best Tip Tracker

The bar: the most simple, intuitive, insightful, intelligent, almost addictive,
and fun tip tracking app in the world, built so it looks, feels, and acts like
Apple made it. Sister app to Vero: calm, evidence-first, no decoration doing
meaning's job. `docs/DESIGN.md` governs how things look; this document governs
what the app does and why.

## The Loop (why someone opens this app every day)

A tipped worker's emotional cycle, and Payday's answer at each beat:

1. **End of shift: "was tonight good?"** → Log in under 10 seconds, then the
   post-log reveal delivers a verdict.
2. **Between shifts: "am I doing okay?"** → Glance: pace line, widget, records.
3. **Payday: "did they pay me right?"** → The payday moment + predicted
   paycheck + one-tap verification.
4. **Over time: "am I getting better?"** → Records, trends, insights.

Everything below serves one of those beats. Features that serve none of them
do not ship.

## Pillar 1: The Post-Log Reveal (the habit engine)

When Save is tapped on a new log, do not just dismiss. Show one card for a
beat (~2s, tappable to dismiss instantly, fully skippable via Reduce Motion):

> **$186 tonight.**
> $34 above your Friday average. Third-best night this period.

Then it flows into the dashboard where the period total rolls up. Rules:

- Computed 100% on-device, instantly (see Pillar 3 stats engine).
- The comparison line varies by what is true: vs weekday average, vs period
  pace, personal records, first-shift-of-period, slowest-in-a-while. One line,
  the most interesting true thing. Never two lines.
- Record nights get the one earned flourish: a single green sweep on the
  amount + distinct success haptic. No confetti, no looping animation.
- Copy is calm and specific. "Nice night." is allowed. Exclamation marks are not.

## Pillar 2: The Payday Moment

The app is named after a moment; honor it. When `daysRemaining == 0`:

- Dashboard leads with the period verdict: final total, best night, vs last
  period ("Your best period yet" when true).
- One action: "When your check lands, enter the tips line and Payday will
  verify it." (TipKit-style one-time education for first-timers.)
- **Predicted paycheck**: the app already knows credit tips for the period, so
  say it plainly: "Your check's tips line should read about $618." When the
  user enters the real stub number, the comparison closes the loop the app
  opened. This is the app's most intelligent feature and it is just a sum.

## Pillar 3: On-Device Stats Engine (instant, private, free)

A small pure module (like `PayPeriodCalculator`: testable, no I/O) computing:

- Pace: total so far vs same point last period; projected period total.
- Records: best night, best [weekday], best period, best month, lifetime total.
- Baselines: average per shift, per weekday, doubles vs singles, cash/credit ratio.
- Anomalies: slowest/best [weekday] in N weeks, streak of shifts logged.

Surfaces: the reveal (Pillar 1), a single pace line under the dashboard hero
("$120 ahead of last period at this point"), the payday moment, and Insights.

## Pillar 4: Insights narration — REVERSED back to OpenAI (2026-07-14)

Originally built on Apple's on-device Foundation Models framework, then
reversed: Apple Intelligence's hardware floor (iPhone 15 Pro+, opt-in
enabled) is too narrow this early to build a feature around — most phones
this app will actually run on can't use it. Insights narration now calls
**OpenAI's `gpt-5.6-terra`** (Responses API, structured JSON output) instead.

- The stats engine still computes every fact; the model still only
  narrates them, never does arithmetic. That discipline doesn't change
  just because the model moved off-device.
- Autonomous, not on-demand: no "Analyze Now" button anywhere. A refresh
  only happens on a visit to Insights, and only if it's actually due —
  facts changed AND at least ~3.5 days since the last refresh ("maybe
  weekly, twice a week at most"). Users see a "last updated" timestamp
  with no control to force it sooner. The one exception: a failed attempt
  sets a flag that bypasses the interval gate entirely, so the very next
  visit retries immediately rather than waiting out the full interval with
  no "Analyze Again" button to fall back on.
- Amend, don't rewrite: each refresh is given the previous narration and
  told to keep every sentence that's still accurate, touching only what
  actually changed. As history builds up, the underlying facts should
  swing less week to week, and the narration should visibly settle down
  right along with them instead of reshuffling on every call.
- Stale narration is shown, never discarded: between refreshes, the last
  narration keeps displaying (labeled "reflects data through ‹date›")
  instead of falling back to the plain stats-engine facts the moment new
  data arrives. Someone logging nightly should see prose almost all the
  time, not robo-facts in the gap between a refresh and their next log.
  The plain facts are strictly a first-run fallback — before any
  narration has ever been generated, or when narration isn't configured.
  **Deviation:** the on-device Foundation Models gate (`isModelAvailable`
  checking hardware support) is gone; the new gate is
  `InsightsService.isConfigured` (an API key present), and the fallback
  path (InsightsFactsCopy's deterministic sections, no narration) now
  covers "not configured" or "network/API call failed" instead of
  "unsupported hardware."
  **Deviation (2026-07-15):** the on-screen "Narration is generated by
  OpenAI…" disclosure line was removed per Tyler's direct call — kept out
  of the footnote entirely now. The underlying fact (computed totals go to
  OpenAI, never raw entries/notes) is still true and still governs what
  the app is allowed to send; it's just not surfaced as UI copy anymore.
- **Key storage, explicit tradeoff, hard release gate:** the OpenAI key
  lives in `Secrets.local.xcconfig` (gitignored) → `OpenAIAPIKey` in
  Info.plist — the exact "key baked into the shipped binary" pattern this
  pillar originally existed to delete. Reintroduced deliberately, fine for
  local builds only. **This app is headed to the App Store** (Tyler,
  2026-07-14 — "not right now, but soon"), which makes this a real,
  time-bounded gate, not a hypothetical: the key MUST move behind a
  backend proxy (so it never ships inside the app bundle) AND be rotated
  (it has already sat in plaintext across multiple chat sessions, so
  treat the current value as burned) before any TestFlight or App Store
  build — not "before any real release" as a vague someday, before that
  specific next step.

## Pillar 5: Woven into the OS (App Intents everywhere)

One set of App Intents, five surfaces. In priority order:

1. `LogTipsIntent` (parameters: amount, kind) → Siri ("log tips in Payday" —
   Siri then asks "how much?" itself via `requestValueDialog`, no app
   launch), Shortcuts. **Deviation from the original four-parameter plan
   (cash, credit, note, double):** a single amount + kind is what a spoken
   flow can actually carry cleanly — asking Siri to collect four slots by
   voice fights the ten-second, thumb-only acceptance test rather than
   serving it. Note and double stay app-only, on the full log sheet.
   `OpenLogSheetIntent` (no parameters, opens the app straight to a blank log
   sheet) covers the case that needs a keyboard: the widget's interactive "+"
   button.
2. `PeriodTotalIntent` → "How much have I made this period?" via Siri and
   Shortcuts, returns the total as a dialog, computed from the same shared
   store and stats engine as the app and the widget.
3. WidgetKit suite: Home Screen small (period total + pace/days left,
   interactive "+" button), Lock Screen circular (total) + rectangular
   (total + pace) + inline (total), StandBy (reuses the accessory families
   automatically — no separate code).
4. Smart Stack relevance: `TimelineEntryRelevance` scored higher during the
   evening shift window and highest on the payday moment itself.
5. Siri, Shortcuts, Spotlight, the Action Button picker, and the Control
   Center shortcut picker are all surfaced by ONE `AppShortcutsProvider`
   declaration (`PaydayShortcuts`) — Apple's own mechanism covers all five
   from a single spot, not five separate integrations.
   **Deviation:** per-entry CoreSpotlight content indexing ("tips friday"
   finds that specific logged entry) was not built — it needs a
   deep-link-by-entry-ID route that doesn't exist yet, and the five surfaces
   above are already covered without it. Worth a follow-up once entries need
   their own deep link for other reasons.

## Pillar 6: Quiet Intelligence (learned, never configured) — DONE

- Learn work rhythm from history: `StatsEngine.workRhythm(referenceDate:)`.
  A weekday is "usual" once worked at least twice AND on at least half its
  actual occurrences since the first logged night (so one Sunday pickup
  shift doesn't get treated like an every-Friday routine). Typical log
  hour is the median of same-day-logged hours (backfills excluded, same
  honesty rule as Insights' lunch-vs-dinner split). No settings for either.
- One smart nudge: `SmartNudgeScheduler` reschedules a single pending
  local notification ("How was tonight?", stable identifier so there's
  never more than one) whenever there's a natural moment to re-check — app
  foreground, and right after every tip log from any entry point (sheet or
  Siri). Fires today at typical-hour+45min if today's a usual night, the
  time hasn't passed, and nothing's logged yet; otherwise the next usual
  night that qualifies. Tapping it deep-links to the log sheet. Permission
  is requested contextually (first real usual-night detection), never
  upfront. On by default with an off-switch in Settings ("Remind me to
  log") — the opposite default from the Face ID lock, since this is a
  built-in behavior you can turn off, not an opt-in.
- Smart defaults in LogTipSheet: a server with zero cash history and
  ≥3 credit entries gets the credit field focused first instead of cash
  (and the keyboard's "Next" button now goes whichever direction isn't
  focused, not just cash→credit, so it still makes sense for them). An
  amount ≥2x the user's average per-shift auto-enables the double toggle —
  a default, not a lock: touching the toggle yourself always wins from
  then on. Date defaults were already right, per the original note.

7/7 items complete. See the final summary for commit hashes and every
deviation across the whole roadmap.

## Pillar 7: Native Behaviors (act like Apple)

- Swipe-delete acts immediately + **Undo toast** (replace the confirmation
  dialog: Apple's grammar is undo, not "are you sure?").
- Context menu on entries: Edit, Duplicate, Delete.
- Keyboard "next" from cash field to credit field; log flow is thumb-only.
- Swift Charts in Insights + Period detail: nightly earnings bar chart,
  scrub-to-inspect with selection haptics (Health-style). Green opacity ramp
  only, per design law.
- TipKit for the two teachable concepts: paycheck verification, double toggle.
- `.sensoryFeedback` for haptics (route through PaydayHaptics).
- iCloud sync via SwiftData + CloudKit and a Face ID lock (LocalAuthentication),
  like Notes. DONE: schema pass gave `TipEntry.id/date/amountCents` and
  `PaycheckRecord.id/periodStart/periodEnd/paidTipsCents` defaults (tested
  against an existing on-device store first — opened clean, no data loss).
  `SharedModelContainer`'s ModelConfiguration now passes
  `cloudKitDatabase: .private("iCloud.com.szakacsmedia.payday")` in the app
  process and `.none` in the widget extension (`WIDGET_EXTENSION` compile
  flag) — only one process should stand up CloudKit's sync engine against
  the same App-Group-shared file. Face ID lock is `AppLockController` +
  `LockGateView`, off by default, toggled in Settings, `.deviceOwnerAuthentication`
  (passcode fallback, like Notes) rather than biometrics-only, and fails
  open with no enrolled passcode at all rather than stranding someone
  outside their own tips.
  **Deviation / blocked on a portal click:** the iCloud and App Groups
  (from item 4) capabilities aren't registered on the App ID yet. Simulator
  builds succeed (they don't enforce provisioning-profile capabilities),
  but a real-device build fails signing with "doesn't include the iCloud
  capability" / "doesn't include the App Groups capability." This needs an
  interactive Xcode signing session or Developer Portal visit — see the
  final summary for exactly what to click.
- Full pass: Dynamic Type (hero amounts get scale factors already; verify at
  AX sizes), VoiceOver labels on day cells/tiles, Reduce Motion on every
  animation including the reveal.

## Pillar 8: The Earnings Engine (Deep Audit Phase 3, 2026-07-14) — DONE

The headline work from the post-a5aa807 adversarial audit: which shifts,
which nights, which choices actually pay. Everything below is the
CloudKit-safe `kindRaw` pattern applied to genuinely-optional fields — plain
`Double?`/`Int?` storage, no computed-accessor split, since "not entered"
and "entered as zero" have to stay distinguishable facts, never collapsed
into a defaulted non-optional.

- **Hours/tip-out/sales are shift-level, by law (2026-07-15).** A product
  ruling, not a UI convenience: hours worked, tip-out, and sales belong to
  the SHIFT (the calendar day), never to an individual entry or tip type.
  A night logged as cash + credit is still one number for each — "5 hours"
  once, not 5 on the credit tab and another 5 on cash. `ShiftDetails`
  (`Payday/Utilities/ShiftDetails.swift`) is the one place this is allowed
  to be read or written: `resolve(from:)` always reads through the
  credit entry when one exists, falling back to cash, and NEVER sums
  across a night's entries; `write(...)` always lands a value on that same
  canonical entry and clears it from every other entry sharing the night,
  self-healing any night that ended up with a value split across both
  (the original bug). `StatsEngine`'s own `NightFacts` grouping enforces
  the identical rule on the analytical side — nightly totals, $/hr, and
  tip percent all resolve through it too, so a corrupted or "wrong-entry"
  night reads the same correct number everywhere, never double-counted.
  `CSVExporter` resolves through `ShiftDetails` as well: one hours/tip-out/
  sales figure per shift row, never a per-entry sum.
- **Hours → $/hr.** Optional `hoursWorked` (half-hour granularity) on
  `TipEntry`, entered in the log sheet's collapsed "Hours, tip-out, sales"
  details group (skippable in under two seconds, remembers a per-weekday
  default). `StatsEngine` blends $/hr by total-dollars-over-total-hours
  (never an average of nightly rates) overall, per weekday, and per
  lunch/dinner/doubles/solo split — only ever over nights that actually
  logged hours. The reveal gains an independent rate clause ("$41/hr, your
  best rate this period") stacked under the usual comparison, never
  replacing it.
- **Net vs gross.** Optional `tipOutCents` on `TipEntry`. Every analytical
  sum in `StatsEngine` — nightly totals, pace, period-to-date, projections,
  Insights totals, Moves — nets a shift's tip-out out automatically via
  `TipRecord.netCents`/`TipEntry.netCents`. The one deliberate exception:
  paycheck comparison keeps reading logged credit as-is (matching what's
  actually printed on a check stub), and tip percent is measured against
  **gross**, matching how the industry always measures it. Gross and the
  tip-out that produced net stay one glance away everywhere net is shown
  (the reveal's gross+tip-out subtitle, the Period-detail hero's "$X tipped
  out" caption) — never hidden, never silently subtracted.
- **Sales + tip percent.** Optional `salesCents` on `TipEntry`. Tip percent
  (gross tips ÷ sales) blends the same total-over-total way as $/hr, overall
  and per weekday, only over nights with sales logged.
- **Moves.** `StatsEngine.moves(referenceDate:)` — a deterministic, pure,
  fully-tested function (no model, no network) emitting up to 3
  dollar-quantified, annualized observations, ranked by impact and gated by
  materiality (silence beats weak advice): weekday swap (net $/night, ≥3
  nights each side), lapsed winner (a strong weekday gone quiet ≥21 days),
  doubles verdict ($/hr, not just $/shift — doubles can look better per
  shift and worse per hour once the extra hours are counted), rate leader
  (best $/hr weekday vs overall), tip-percent signal (best tip-% weekday vs
  overall). Rendered as cards at the TOP of Insights, above the chart —
  always fresh, never narrated. The single best move is fed into the
  gpt-5.6-terra prompt as a fact block so the model's closing suggestion can
  reference it, but the cards themselves never touch the model.
- **Projection.** `StatsEngine.projectedPeriodTotal(period:asOf:rhythm:)` —
  current net total plus one estimated night (at that weekday's own
  historical average) for every remaining calendar day that lands on a
  usual weekday. One quiet line under the Dashboard's pace line ("On pace
  for about $1,240"); suppressed entirely without a rhythm yet to project
  from.
- **Year view + CSV export.** A compact year-to-date card atop the Periods
  tab (net total + shift count, current calendar year). A toolbar
  `ShareLink` exports `CSVExporter`'s output — one row per calendar night
  (cash and credit merged, same "a shift, not a row" rule as
  `ShiftDayRow`): date, cash, credit, tip-out, net, hours, sales, double,
  note, the night's own period range, and its matched paycheck if any. No
  new dependencies; the file is written to a stable temp path so repeat
  exports overwrite instead of accumulating.

## Pillar 9: Multiple Jobs — DESIGN ONLY, implementation gated (2026-07-14)

Design committed ahead of code per Tyler's standing instruction: scope this
honestly and stop for a check-in before writing any Phase 4 code, since one
piece of it is a real architectural decision, not just a schema add.

**Model.** A new `Job` SwiftData model: `name: String`, optional
`paySchedule: PaySchedule?` (CloudKit-safe — nil means "use the app's shared
schedule," not "broken"), `colorTag` deferred (no new hues per design law;
jobs differentiate by name/label, not color, same "text-forward" rule as
everywhere else in this app). `TipEntry` gains an optional `job: Job?`
relationship — same optional-relationship pattern as every field added this
phase, genuinely low-risk on its own: SwiftData/CloudKit lightweight-migrate
an added optional relationship the same way they migrated `hoursWorked`,
`tipOutCents`, and `salesCents` this session. Every existing entry has
`job == nil`; that is not a migration hazard, it is the definition of "no
second job yet."

**Invisibility until it matters.** Zero or one job (the common case) is
today's app, byte-for-byte — no new UI appears anywhere until a second job
exists. Jobs are created in Settings > Jobs. The moment a second job is
created, per-job UI switches on everywhere at once.

**With 2+ jobs:**
- Log sheet gains a job picker, remembering the last job used per weekday
  (same per-weekday-memory pattern as hours/tip-out/sales this phase).
- Periods and paycheck verification become per-job: a period and its
  paycheck comparison belong to one job's own schedule, never a blend.
- `StatsEngine`, Insights, and Moves become job-aware and gain a genuinely
  new capability neither has today: cross-job comparison ("Harry's pays $6
  more than The Anchor on Fridays"; "Harry's averages $22/hr against The
  Anchor's $15/hr").

**The one real design fork — needs Tyler's steer before implementation:**
Dashboard's hero is built around ONE period ("This pay period," one total,
one pace line, one projection). Two jobs on independent schedules (e.g.
biweekly Mon–Sun vs. weekly Wed–Tue) have no shared period boundary — there
is no single "this pay period" once schedules disagree. "Combined by
default with a one-tap job filter" (as specced) has to mean one of:
  (a) the combined view is by CALENDAR WINDOW (today / this week / this
      month), not by period, with "period" only appearing once a single
      job is filtered to, or
  (b) the combined view shows each job's own current period as its own
      row/card stacked together, with no single blended total at all, or
  (c) jobs are required to share one schedule (defeating "optional
      per-job PaySchedule" as specced).
None of these is obviously correct without knowing which case Tyler is
actually solving for (two jobs that happen to share a payday cadence vs.
two genuinely independent schedules) — this is the one thing worth a real
conversation before code, not a judgment call to make solo. Everything
else above (the model, the invisibility rule, the picker, per-job
periods/paychecks, StatsEngine's cross-job facts) is straightforward to
build once that fork is resolved.

## Pillar 10: The Climb to 90 (analysis-quality mission, 2026-07-15)

An adversarial audit scored the analysis feature 62/100 on one axis — "does
this help a tipped worker make more money" — and found it held back by a
proxy where a fact should be, no sample-size humility, advice with no
follow-up, single-venue blindness, and no forward planning. Four phases
close that gap; each ships as its own commit series.

### Phase A: Data Honesty (+6) — DONE

- **Lunch/dinner is a captured fact now, not just inferred.** New optional
  `shiftPeriod` (`ShiftPeriod?`, `lunch`/`dinner`) on `TipEntry` — same
  CloudKit-safe raw-string-to-enum split as `kind`, but WITHOUT a
  non-optional fallback: "never set" is a real, meaningful state here, so
  the accessor stays `Optional` all the way through, never defaulted. Same
  per-shift semantics as hours/tip-out/sales: canonical entry (credit
  preferred), heals strays, resolved/written through `ShiftDetails`
  alongside the other three. The log sheet's details group gains a
  Lunch/Dinner segmented control, pre-selected from the clock (before 4 PM
  → Lunch) whenever the shift being logged is actually today — a
  backfilled past day has no clock to trust, so it starts unset rather
  than guessed at. A double shift hides the picker entirely and clears any
  stale value (isDouble already means "both"). `StatsEngine.lunchDinnerFacts`
  and the lunch/dinner split inside `RateFacts` now use the explicit value
  first, falling back to the same-day-logged `recordedAt` proxy only for
  legacy nights that never captured one — and both now count a night ONCE
  regardless of how many cash/credit records it has, fixing a latent
  double-count for any night with both.
- **Sample-size humility.** Every Move body now states the counts on both
  sides ("across 8 Fridays and 5 Mondays"); `InsightsFactsCopy`'s
  hourly-rate and tip-percent "best weekday" callouts do the same
  (`RateFacts`/`SalesFacts` gained `bestWeekdayNightCount`); the terra
  prompt mirrors it. The reveal's weekday-average line stays clean at 5+
  nights of history for that weekday; below that it self-discloses with
  "(across N Fridays)" rather than sounding more confident than the sample
  actually supports.
- **Variance guard on weekday comparisons.** `weekdaySwapMove` and
  `rateLeaderMove` now require the delta to clear `max(flatFloor, 0.6 ×
  pooledStandardDeviation)` — a pooled per-night SD across both sides being
  compared — before firing, not just a flat dollar floor. 0.6 is a
  deliberate calibration ("roughly more than half a standard deviation
  apart"), not derived from anything; tune `MoveThresholds.varianceGuardFactor`
  if Moves reads too eager or too quiet in practice. weekdaySwapMove's flat
  floor also rose from $10 to $15 in the same pass.

### Phase B: Close the Loop (+8) — not started
### Phase C: Multiple Jobs (+8) — not started (design already committed, d01e7de)
### Phase D: Plan Forward (+6) — not started

### Explicitly deferred (out of scope)

- Benchmarking against other users.
- POS/scheduler integrations.
- App-proposed experiments.

## What NOT to build (the restraint is the product)

- No goals, budgets, or guilt-mechanic streaks. Records replace streaks.
- No social anything, no leaderboards, no sharing cards (for now).
- No chat. Ask Vero exists; Payday is a tool, not an assistant.
- No accounts, ever. iCloud is the sync story.
- No confetti, no mascots, no gamification currency. Fun comes from meaning:
  reveals, records, pace, the payday moment.

## Priority order (build in this sequence)

1. Stats engine + post-log reveal + dashboard pace line (the habit loop core).
2. On-device Foundation Models swap for Insights narration — REVERSED
   2026-07-14, see Pillar 4. Now OpenAI gpt-5.6-terra over the network,
   autonomous ~twice-weekly refresh, amend-not-rewrite, with a hard
   release gate on moving the key behind a proxy and rotating it.
3. Payday moment + predicted paycheck (+ TipKit explainer).
4. App Intents + widgets (+ Smart Stack relevance).
5. Undo-over-confirm, context menus, keyboard next, Swift Charts.
6. CloudKit schema pass + sync + Face ID lock.
7. Smart nudge + smart defaults.

Each numbered item should be a separate PR-sized commit series with tests for
the stats engine (pure module: test it like PayPeriodCalculator) and light/dark
screenshots for every new surface.

## Acceptance test

Hand the phone to a server after their shift. They should be able to log and
get their verdict in under ten seconds without instruction. Two weeks later
they should be checking the widget on off-days and telling a coworker "it
knows my Fridays." And a reviewer should plausibly ask "wait, is this Apple's?"
