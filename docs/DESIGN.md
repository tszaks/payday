# Payday Design: The Vero Family Language

Payday is a sister app to Vero. Two different products, one unmistakable family
feel, the way every Google app feels like Google. This is achieved the same way
Google does it: shared tokens and shared behaviors, not resemblance by accident.

The source of law is Vero's design thesis (`AskVero/ios/docs/VERO_VISION.md`).
This document translates it for Payday. Where the two documents disagree, Vero's
wins, then this one gets fixed.

Three words govern every decision, same as Vero: **effortless, simple,
intelligent.** And the same meta-rule applies: beautiful, considered design
outranks every rule below. If following a rule literally makes a screen worse,
the rule is being applied wrong. Look at the render.

## The Family Contract (what makes it feel like one company)

1. **One green.** `#00B83F`. It is the only color that acts: every button,
   active state, selection, and interactive accent is this green or neutral.
   Payday's current accent (`#30D158`, Apple system green) is retired. Blue,
   purple, and every other hue do not exist.
2. **White and black build structure.** Light mode is alabaster and ink:
   `#FAFAFA` background, pure white cards that lift off it with a physical
   shadow, true black text. Dark mode is obsidian: `#050505` background,
   `#121212` cards, darkness itself is the shadow. Light and dark are co-equal
   designs, not one design and its inversion. (This replaces Payday's current
   pure-white/pure-black `paydaySurface`.)
3. **Two warning signals, both semantic.** Caution (orange in light
   `#E8590C`, amber in dark `#FF9F0A`) means watch out. Error red (`#FF3B30`)
   means problem. In Payday, a paycheck that shorted you is error red; that is
   a real signal, keep it. Nothing else gets a warning color.
4. **One font family.** SF Pro everywhere. Money is SF Pro Rounded, heavy
   weight, fixed display sizes, exactly like Vero (and Apple Wallet). Every
   financial number carries `.monospacedDigit()` so layout never shifts, and
   `.contentTransition(.numericText())` so values roll instead of snap. UI text
   uses semantic Dynamic Type styles with bumped weights. No raw
   `.font(.system(size:))` for UI text.
5. **Text-forward.** Differentiation comes from label, weight, and structure,
   never icon clutter. SF Symbols only where genuinely the clearest signal,
   sparingly, neutral. No emojis, anywhere, ever.
6. **Glass is chrome, content is solid.** Native `glassEffect` belongs only to
   the layer that floats: tab bar, toolbars, prominent action buttons, sheets.
   Cards and rows are solid fills. Since Payday targets iOS 26 only, no
   fallback wrappers are needed; still route glass through shared helpers, not
   ad hoc call sites.
7. **Motion is information.** One spring per interaction class, drawn from
   shared timing tokens. Nothing loops on stable content. Every timed animation
   respects Reduce Motion.
8. **Haptics communicate state.** Success notification only for a real save.
   Light tap for navigation-level actions. Routine, reversible changes are
   silent.
9. **The Vero Touch.** The resting state of every screen answers one question
   with one focal object; everything deeper is one calm tap away. Payday's
   Dashboard already does this (the period total is the answer); protect it.
10. **Calm, specific copy.** Evidence before advice. "Fridays average $142,
    your best day" beats "You should work more Fridays." No exclamation marks
    doing the enthusiasm's job.
11. **Say it once.** No screen states the same fact twice. A progress bar that
    is full, a label reading "Last pay period", and a header reading "Period
    complete" are one fact billed three times; two of them are clutter. This
    applies to dates (the bar already labels payday, so no caption repeats it),
    to instructions (no sentence telling the person to do what the button
    directly below it does), and to titles (no subtitle that paraphrases the
    title it sits under). A derived fact is not a repeat: "That's 6h 23m" under
    a start and end time earns its place because it does arithmetic the reader
    would otherwise do. Before adding a line, find what already says it, and
    delete one of them. (Tyler, 2026-08-03, after the Dashboard payday card
    accumulated seven numbers to answer one question.)
12. **One direction per ledger.** Any breakdown of money runs additions, then a
    subtotal, then subtractions, then the total. Never alternating: cash, credit,
    tipped out, wages, overtime makes the reader track a sign that flips twice
    down a five-row column. "Up, up, up, then down" (Tyler's phrasing).
    Every figure on the card face must reconcile to the hero above it. A closed
    drawer showing gross figures that sum to more than the total they sit under
    is a card arguing with itself.

## Implementation Plan

### Phase 1: Port the token file (the foundation, ~1 hour)

Copy Vero's `Vero/Core/Design/DesignSystem.swift` into
`Payday/Design/DesignSystem.swift` with a mechanical rename `Vero` → `Payday`
(`PaydayColor`, `PaydayFont`, `PaydaySpacing`, `PaydayRadius`,
`PaydayAnimation`, `PaydayHaptics`, `PaydayShadow`). Values stay identical,
byte for byte. Drop what Payday has no use for (command bar, agent status,
composer tokens) and drop the pre-iOS-26 fallback branches inside the glass
helpers since Payday's floor is 26.

Then:
- Set the AccentColor asset to `#00B83F`.
- Delete `Color.paydaySurface`; its call sites move to `PaydayColor.background`
  / `.cardBackground` / `.fieldBackground` depending on role (page, lifted
  card, inset field).
- Replace `Haptics` with `PaydayHaptics` (same tiers as Vero).

Long term (post-App Store, optional): extract one shared `VeroDesignKit` Swift
package both apps import, so a token change ships to the whole family. Not
worth blocking on now; identical values in two files gets 100% of the look for
0% of the migration risk to Vero.

### Phase 2: Restyle each screen against the contract

**Dashboard**
- Page background `PaydayColor.background` (alabaster/obsidian). Hero becomes a
  true card: `cardBackground` + `paydayPremiumShadow()` (the 3-layer diffusion
  in light, minimal in dark).
- Hero amount: `PaydayFont.displayXXL` (60pt heavy rounded) + monospacedDigit.
- StatChips and MoneyTiles: drop the calendar and briefcase icons (text-forward:
  the label already says it), solid `fieldBackground` fills, caption labels.
- "Log Tips" button: green prominent glass, text only, no plus icon.
- Empty state: `ContentUnavailableView`, neutral symbol, calm copy.
- Delete swipe stays; add no icons to rows. EntryRow subtitle (kind, time,
  note) is already the family voice.

**Calendar**
- Day-cell heat already follows the data-viz law (one hue, opacity steps);
  it just becomes the right green automatically via the accent swap.
- Month header chevrons are fine (functional, not decorative).
- Add combined accessibility labels to day cells ("July 12, $118 logged").

**Periods / Period Detail**
- Rows: amounts in rounded semibold with monospacedDigit; delta keeps
  green-positive / error-red-negative semantics.
- The paycheck comparison block is Payday's "evidence before advice" moment;
  its explanatory captions are exactly the family voice. Keep and protect.

**Log / Edit / Paycheck sheets**
- Sheets are chrome, so their glass presentation is correct; interior fields
  use `fieldBackground` (grey inset edge), never white-on-white.
- Follow the Vero sheet standard: creation flows are Cancel + commit (Log Tips
  is already correct); edit flows live-save with a single Done button (Edit
  Tips currently uses Cancel/Save and should convert).
- Amount displays: rounded heavy + monospacedDigit + numericText.

**Insights**
- The prompt already enforces evidence-before-advice and bans AI disclaimers;
  that is the Vero voice. Keep.
- Loading state should not evict the previous result (calm over noisy): keep
  the list visible with progress in the footer.
- Section list stays text-only. No icons per section.

**Settings / First-run**
- Form insets on `fieldBackground` over the page background.
- First-run copy is already calm and two-question simple; keep.

**App icon**
- Same family: the Liquid Glass icon recolored to build from `#00B83F` on
  white / obsidian, visually related to Vero's icon the way Gmail relates to
  Drive: same palette, different glyph.

### Phase 3: Enforcement (so it never drifts)

- Port Vero's `scripts/design-lint.sh` with Payday paths. Zero-tolerance rules:
  inline hex outside DesignSystem.swift, `Color(red:)` literals, forbidden hues
  (blue/purple/indigo/cyan/mint/teal/pink), raw `.font(.system(size:))` outside
  sanctioned display/icon tokens, emojis in source, raw haptic generators
  outside PaydayHaptics.
- Run it in CI once Payday has CI; until then, run before every commit.

## What NOT to copy from Vero

- No chat, no command bar, no Radar. Family feel is shared language, not
  shared features. Payday stays a fast, single-purpose tool.
- Vero's iOS 17 fallback machinery. Payday is iOS 26+; keep it lean.
- Vero's fixed-size money readability exception is inherited deliberately, but
  Payday should still verify hero amounts at the largest Dynamic Type sizes.

## Acceptance test

Put Dashboard (Payday) next to Home (Vero) on two phones, both modes. A
stranger should say: same company, obviously. Same green acting, same paper
and obsidian, same heavy rounded money, same calm. If they'd guess two
different developers, Phase 2 isn't done.
