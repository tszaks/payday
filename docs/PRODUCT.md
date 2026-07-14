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

## Pillar 4: Apple Intelligence, literally (replaces OpenAI)

Replace the OpenAI integration with Apple's on-device **Foundation Models
framework** (iOS 26, `import FoundationModels`, `LanguageModelSession`,
`@Generable` guided generation for typed sections output).

- The stats engine computes facts; the model narrates them. Never let the
  model do arithmetic: pass computed stats in, get calm sentences out.
- Regenerate after data changes (cheap + local), so Insights is always current.
- Delete: the OpenAI key from Secrets.local.xcconfig + project.yml + Info.plist,
  the network code, the rate limiter, the weekly auto-refresh, and the
  "sends your data to OpenAI" disclosure. Nothing leaves the phone, say so.
- Gate gracefully: Foundation Models requires Apple Intelligence-capable
  hardware. If unavailable, Insights shows the stats-engine facts without
  narration (which must stand alone anyway).
- This deletes the P0 key-in-bundle security issue permanently.

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

## Pillar 6: Quiet Intelligence (learned, never configured)

- Learn work rhythm from history (which weekdays, typical log time). No
  settings for any of this.
- One smart nudge: if it is a usual work night and nothing is logged by ~45min
  past their usual time, one local notification: "How was tonight?" →
  deep-links to the log sheet. Never more than one per day; silence is a
  valid answer; easy off-switch in Settings.
- Smart defaults: credit-only loggers get credit focused first; an amount
  ~2x the user's average offers the double toggle; date defaults are already
  right.

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
  like Notes. NOTE: CloudKit requires all properties optional or defaulted;
  `TipEntry.id/date/amountCents` are currently neither. Do this schema pass
  BEFORE the first App Store build so the store never needs a breaking
  migration after real users exist.
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
2. Foundation Models swap, OpenAI deletion (kills P0, makes Insights instant).
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
