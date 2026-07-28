# Payday marketing assets

## App Store screenshots

`store-screenshots/` holds the composed 6.9" (1320x2868) frames uploaded to
App Store Connect. They are generated, not hand-edited:

1. Seed the screenshot simulator (deterministic — same numbers every run):
   `xcrun simctl launch <iPhone-17-Pro-Max-UDID> com.szakacsmedia.payday -SeedShowcase`
   Useful extras: `-InitialTab calendar|insights`, `-OpenCurrentPeriodDetail`.
2. Capture raw frames to the repo root as `Payday Screenshot N.png`.
3. `python3 scripts/make-store-screenshots.py`

The composition matches Vero's marketing family: light canvas, Didot
headline, quiet subhead, dark device below. Headlines and subheads live in
the SHOTS list at the top of the script — edit them there, not in an image
editor, so a re-render never loses the copy.
