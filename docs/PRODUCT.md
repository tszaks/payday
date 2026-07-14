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
- One-line disclosure, always visible whenever narration is configured:
  "Narration is generated by OpenAI from your computed totals — never
  your raw entries or notes." Every "nothing leaves the phone" claim was
  correctly scrubbed (app and site) when this pivoted; this replaces it
  rather than leaving the honesty gap open — the app does now send
  computed facts off-device, automatically, and has to say so.
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
