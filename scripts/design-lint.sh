#!/usr/bin/env bash
# Payday Design Lint — enforces the Vero-sister-app design contract
# (docs/DESIGN.md), ported from Vero's scripts/design-lint.sh.
# Zero-tolerance rules only: every check below must report 0 violations.
#
# Run locally:  ./scripts/design-lint.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

# grep over app sources only; tests/build excluded
SRC=(Payday)

run_check() {
  local name="$1" pattern="$2" exclude_re="$3" hint="$4"
  local hits
  hits=$(grep -rn -E "$pattern" "${SRC[@]}" --include="*.swift" 2>/dev/null | grep -Ev "$exclude_re" || true)
  if [ -n "$hits" ]; then
    FAIL=1
    echo "[FAIL] $name"
    echo "$hits" | sed 's/^/   /'
    echo "   -> $hint"
    echo ""
  else
    echo "[PASS] $name"
  fi
}

echo "=== Payday Design Lint ==="
echo ""

# 1. Raw glassEffect application belongs in DesignSystem.swift wrappers only.
run_check \
  "No raw .glassEffect() outside DesignSystem" \
  '\.glassEffect\(' \
  'Design/DesignSystem\.swift' \
  "Use paydayNativeGlassCapsule/Circle/RoundedRectangle; add a new wrapper to DesignSystem.swift for new shapes"

# 2. Haptics route through PaydayHaptics (Low Power Mode aware).
run_check \
  "No raw haptic generators outside DesignSystem" \
  'UI(Impact|Notification|Selection)FeedbackGenerator\(' \
  'Design/DesignSystem\.swift' \
  "Use PaydayHaptics.lightTap()/medium()/success()/error()/selection()"

# 3. No hardcoded RGB colors — PaydayColor or semantic system colors only.
run_check \
  "No Color(red:green:blue:) literals" \
  'Color\(red:' \
  '__never_matches__' \
  "Add an entry to PaydayColor (adaptive lightHex/darkHex) instead"

# 4. No inline hex color literals outside the design system.
run_check \
  "No Color(hex:) calls outside DesignSystem" \
  'Color\(hex:' \
  'Design/DesignSystem\.swift' \
  "Route colors through PaydayColor or an approved semantic token"

# 5. One accent color acts (green). Blue and the rest of the spectrum are retired.
run_check \
  "No forbidden hues (blue/purple/indigo/cyan/mint/teal/pink)" \
  '(\.(blue|purple|indigo|cyan|mint|teal|pink)\b|Color\.(blue|purple|indigo|cyan|mint|teal|pink)\b|system(Blue|Purple|Indigo|Cyan|Mint|Teal|Pink))' \
  'Design/DesignSystem\.swift' \
  "Use PaydayColor.primary (green), a neutral, or PaydayColor.caution/.error for warnings"

run_check \
  "No raw semantic color members" \
  '(foreground(Color|Style)\(\.(red|green|orange|yellow)\b|\.tint\(\.(red|green|orange|yellow)\b|iconColor: \.(red|green|orange|yellow)\b|color: \.(red|green|orange|yellow)\b|Color\.(red|green|orange|yellow)\b)' \
  'Design/DesignSystem\.swift' \
  "Use PaydayColor.primary, PaydayColor.caution, PaydayColor.error, or neutral tokens instead of raw semantic colors"

# 6. No serif fonts — amounts use SF Pro Rounded heavy.
run_check \
  "No serif font references" \
  '(DMSerifDisplay|PlayfairDisplay|serifDisplay|serifLargeTitle|serifTitle|serifHeadline|serifFontName)' \
  '__never_matches__' \
  "Use the SF Pro Rounded display tokens (PaydayFont.display*)"

# 7. No raw font(.system(size:)) for UI text — every size routes through PaydayFont.
run_check \
  "No raw .font(.system(size:)) outside DesignSystem" \
  '\.font\(\.system\(size:' \
  'Design/DesignSystem\.swift' \
  "Use a PaydayFont display or semantic token instead of a raw point size"

# 8. Authentic Apple glass ONLY. Raw materials are never a Payday content surface.
run_check \
  "No raw materials outside DesignSystem (authentic glass only)" \
  '\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|ultraThickMaterial)\b' \
  'Design/DesignSystem\.swift' \
  "Glass routes through paydayNativeGlass* wrappers (system glassEffect). Content is solid PaydayColor, never material"

# 9. No fake glass wrappers — native glassEffect only.
run_check \
  "No fake glass wrappers" \
  '(struct Blur|Blur\(|UIBlurEffect|UIVisualEffectView|systemThinMaterialLight|systemThinMaterialDark)' \
  '__never_matches__' \
  "Use native glassEffect where available and .ultraThinMaterial fallback only"

# 10. No emojis in USER-FACING strings. Developer log lines (print/os_log) are
#     excluded since they're not product voice. Perl is portable across macOS
#     (BSD) and Linux CI runners where grep -P is not.
EMOJI_HITS=$(find "${SRC[@]}" -name '*.swift' -print0 2>/dev/null \
  | xargs -0 perl -CSD -ne '
      next if /(logger\.|console\.|os_log|Logger\(|\bprint\(|\.debug\(|\.info\(|\.warning\(|\.error\(|\.notice\(|\.fault\(|\.critical\(|#warning|#error)/;
      print "$ARGV:$.: $_" if /[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{1F1E6}-\x{1F1FF}\x{FE0F}\x{20E3}]/ || /\\u\{(?:1F[0-9A-Fa-f]{3}|2[67][0-9A-Fa-f]{2}|2B[0-9A-Fa-f]{2}|FE0F|20E3)\}/;
      close ARGV if eof;
    ' 2>/dev/null || true)
if [ -n "$EMOJI_HITS" ]; then
  FAIL=1
  echo "[FAIL] No emojis in source"
  echo "$EMOJI_HITS" | sed 's/^/   /'
  echo "   -> Payday never uses emojis. Remove them from strings entirely."
  echo ""
else
  echo "[PASS] No emojis in source"
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
  echo "=== Design lint FAILED — see docs/DESIGN.md ==="
  exit 1
fi
echo "=== Design lint passed ==="
