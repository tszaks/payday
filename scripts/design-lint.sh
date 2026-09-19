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

# grep over app + widget extension sources; tests/build excluded
SRC=(Payday PaydayWidget)

# Every source line as `path:line:text`, with comments and string CONTENTS
# blanked. Built once; every rule below greps this instead of the raw files.
#
# The reason is a false positive this script produced on its own explanatory
# comments: a rule of the form "this spelling must not appear outside these
# files" cannot distinguish a CALL from a MENTION, so a header that quoted the
# banned spelling in order to explain why it must never be used was reported as
# using it. That is the repo's most expensive recurring bug class -- a check
# that invents its own answer -- and it had already been paid for three times
# elsewhere. Blanking once, centrally, removes it from all rules at once
# instead of rewording every comment that trips one.
SOURCE_STREAM=$(mktemp)
trap 'rm -f "$SOURCE_STREAM"' EXIT
perl scripts/lint-blank-comments.pl "${SRC[@]}" > "$SOURCE_STREAM"

run_check() {
  local name="$1" pattern="$2" exclude_re="$3" hint="$4"
  local hits
  hits=$(grep -E "$pattern" "$SOURCE_STREAM" 2>/dev/null | grep -Ev "$exclude_re" || true)
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
# PaydayWidgetAccessoryViews.swift is exempt: Lock Screen/StandBy accessory
# widgets are rendered by the system in its own monochrome tint, ignoring
# any PaydayColor set there, and Apple's own guidance is plain system fonts
# to match other Lock Screen widgets rather than the app's brand type scale.
run_check \
  "No raw .font(.system(size:)) outside DesignSystem" \
  '\.font\(\.system\(size:' \
  'Design/DesignSystem\.swift|PaydayWidgetAccessoryViews\.swift' \
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
echo "=== Shift representation invariants (PR 2) ==="
echo ""

# 11. The earnings schema version has ONE owner.
#     ShiftReceiptMetrics.swift decides what v1 and v2 mean and is the only
#     file allowed to relabel a payload. A second writer is a money bug: it
#     marks a payload v2 without performing the subtraction that makes it v2,
#     and every later reader then trusts the label.
#
#     LogTipSheet.swift:1053 is a pre-existing violation, excluded here and
#     NOT forgiven. It is `gratuityFeesBinding`, the legacy two-row edit path,
#     which S9 replaces with ShiftCommands.update. Delete this exclusion in
#     S9 — the ban has no teeth against the edit path until then.
run_check \
  "earningsSchemaVersion is assigned only in ShiftReceiptMetrics.swift" \
  'earningsSchemaVersion *=' \
  'Utilities/ShiftReceiptMetrics\.swift|Views/Shared/LogTipSheet\.swift' \
  "Go through ShiftReceiptMetrics.normalizedToV2. Relabelling a payload without subtracting its folded gratuity double-counts that money forever"

# 12. The v1-to-v2 read rule has ONE caller surface.
#     voluntaryTipsCents is the READ path's normalization. A new caller is how
#     a second, subtly different version of the rule gets written (the edit
#     path moves the WHOLE gratuity to the other kind; the read path subtracts
#     it from the owner only — $22.00 apart on the N4 shape, and a different
#     cash/credit split, which is what drives the paycheck comparison).
#
#     TipBreakdown.swift and StatsEngine.swift are the two permanent legacy
#     read legs (tip_entries stays a write surface indefinitely, so the legacy
#     projection never goes away) and are the "before" side of the section 11
#     parity gate. They are excluded because they are the rule's existing
#     consumers, not because a new one would be acceptable.
run_check \
  "voluntaryTipsCents( is called only from its own file and the two legacy read legs" \
  'voluntaryTipsCents\(' \
  'Utilities/ShiftReceiptMetrics\.swift|Utilities/TipBreakdown\.swift|Utilities/StatsEngine\.swift' \
  "Read a shift's money through ShiftRecord/the projection, or add the case to ShiftReceiptMetrics.swift. Do not re-derive the v1 split"

# 13. ShiftRecord.receiptMetrics is ENCODE-ONLY and has one writer.
#     Assigning the decoded value moves no money by itself, which is exactly
#     the hazard: cash/credit/receipt have to change together or the split
#     drifts. ShiftRecord.applyEarnings is the atomic writer.
#
#     grep cannot type-check a receiver, so this bans the spelling everywhere
#     except the files that legitimately write a TipEntry's payload. That is
#     stricter than the rule as written (it also pins the legacy sites), which
#     is the safe direction.
run_check \
  "No .receiptMetrics = outside ShiftRecord.swift and the legacy TipEntry writers" \
  '\.receiptMetrics *=' \
  'Models/ShiftRecord\.swift|Models/TipEntry\.swift|Utilities/ShiftDetails\.swift|Utilities/StatsEngine\.swift|Sync/PaydayRemoteModels\.swift|Sync/PaydaySyncService\.swift' \
  "Use ShiftRecord.applyEarnings(cashCents:creditCents:metrics:metricsOwner:) so cash, credit and the payload change in one step"

# 14. The gratuity rule has ONE implementation in SQL.
#     private.receipt_gratuity_cents is read by two STORED generated columns,
#     by the deriver's arithmetic and by the fold's sanitizer. A fourth
#     hand-written `->> 'gratuityFeesCents'` is a copy of a money rule that
#     drifts silently: CREATE OR REPLACE on the function does not recompute
#     any stored row, so the copies and the stored values disagree with no
#     error anywhere.
#
#     Allowed ONLY inside private.receipt_gratuity_cents' own body, and the
#     exemption ENDS at that body's closing dollar-quote. An earlier version
#     set the flag on the `create ... function` line and never cleared it, so
#     every later line in the same file was forgiven — PROVEN: the real helper
#     followed by
#       bad_gratuity integer generated always as
#         ((receipt_metrics ->> 'gratuityFeesCents')::integer) stored
#     reported [PASS], which is the int4-space spelling 2.3 measured as
#     aborting with 22003 inside a shipped 1.0 build's transaction.
#
#     The fold gets NO exemption and needs none: 2.5's sanitizer spells the
#     key as a jsonb PATH, '{gratuityFeesCents}', which this pattern (the key
#     followed by a closing quote) does not match at all, and the fold's
#     arithmetic goes through the helper. A blanket exemption on
#     private.fold_legacy_writes would buy nothing and permanently un-guard
#     the one function that runs inside a 1.0 build's transaction.
#
#     20260904125000 predates public.shifts entirely and reads tip_entries, so
#     it is excluded by name.
SQL_GRAT_HITS=$(find supabase -name '*.sql' -print0 2>/dev/null \
  | xargs -0 awk '
      function scan_dollar_quotes(line,   rest, tag) {
        rest = line
        while (match(rest, /\$[A-Za-z_0-9]*\$/)) {
          tag = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (dq == "") {
            dq = tag
          } else if (tag == dq) {
            dq = ""
            fn = ""
          }
        }
      }
      FNR == 1 { fn = ""; dq = "" }
      {
        if (dq == "" && $0 ~ /^[[:space:]]*create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?function/) {
          fn = ""
          if (match($0, /private\.receipt_gratuity_cents/)) fn = "helper"
        }
        if ($0 ~ /gratuityFeesCents'"'"'/ && fn != "helper") {
          printf "%s:%d: %s\n", FILENAME, FNR, $0
        }
        scan_dollar_quotes($0)
        # A function body that is not dollar-quoted ends at its statement
        # terminator. Without this the exemption would again outlive the body.
        if (dq == "" && index($0, ";") > 0) fn = ""
      }
    ' 2>/dev/null \
  | grep -v '20260904125000_optimize_payday_summary_and_shift_listing\.sql' || true)
if [ -n "$SQL_GRAT_HITS" ]; then
  FAIL=1
  echo "[FAIL] gratuityFeesCents' appears in SQL outside private.receipt_gratuity_cents' body"
  echo "$SQL_GRAT_HITS" | sed 's/^/   /'
  echo "   -> Call private.receipt_gratuity_cents(receipt_metrics). It clamps in numeric space; a hand-written cast aborts with 22003 inside a shipped 1.0 build's transaction"
  echo ""
else
  echo "[PASS] gratuityFeesCents' appears in SQL only inside the gratuity rule"
fi

# 15. No WHERE on an ON CONFLICT targeting public.shifts.
#     MEASURED on PG 17: `insert ... on conflict (user_id,id) do update ...
#     where deleted_at is null` against a matching-but-excluded row reports
#     INSERT 0 0 and leaves the row untouched — no error. Under this shape
#     that statement runs inside a shipped 1.0 build's transaction, so a
#     silently-skipped upsert means the arriving legacy id is never recorded,
#     and any raise afterwards rejects that build's write. The partition has to
#     stay total, which means a CASE per column and never a predicate.
#
#     Checked as "a WHERE belonging to the ON CONFLICT clause itself", which
#     means the two WHEREs that are NOT the predicate have to be excluded:
#
#       * a source filter BEFORE it -- `insert ... select ... where ... on
#         conflict ...` -- which the rule's first version already allowed by
#         only looking forward from the `on conflict` token; and
#       * a WHERE anywhere AFTER it that belongs to a different clause. S6's
#         writer is one `with ... insert ... on conflict ... returning`
#         statement whose other CTEs and whose final SELECT both filter, so
#         looking forward for any WHERE at all flagged it with no predicate
#         present. Same class of false positive as the first one, in the other
#         direction.
#
#     So the scan is paren-depth aware: from the `on conflict` token it walks
#     forward and reports a WHERE only at the depth the token itself sits at,
#     stopping as soon as depth goes negative (the enclosing CTE or statement
#     has closed). `on conflict (cols) where <index predicate> do update` and
#     `do update set ... where <condition>` are both at that depth and are
#     still caught; a WHERE inside a subquery in the SET list is not, which is
#     correct -- it cannot skip the row.
SQL_CONFLICT_HITS=$(find supabase -name '*.sql' -print0 2>/dev/null \
  | xargs -0 awk '
      function conflict_predicate(text,    i, d, ch, rest) {
        # text starts at the "on conflict" token. Depth 0 is the clause.
        d = 0
        for (i = 1; i <= length(text); i++) {
          ch = substr(text, i, 1)
          if (ch == "(") { d++; continue }
          if (ch == ")") { d--; if (d < 0) return 0; continue }
          if (d == 0 && substr(text, i, 7) == " where ") return 1
        }
        return 0
      }
      FNR == 1 { stmt = ""; start = 0 }
      {
        line = tolower($0)
        sub(/--.*$/, "", line)
        if (stmt == "") start = FNR
        stmt = stmt " " line
        if (index(line, ";") > 0) {
          if (index(stmt, "public.shifts") > 0) {
            c = index(stmt, "on conflict")
            if (c > 0 && conflict_predicate(substr(stmt, c))) {
              printf "%s:%d: statement beginning here has a WHERE on its ON CONFLICT clause\n", FILENAME, start
            }
          }
          stmt = ""
        }
      }
    ' 2>/dev/null || true)
if [ -n "$SQL_CONFLICT_HITS" ]; then
  FAIL=1
  echo "[FAIL] ON CONFLICT with a predicate WHERE on public.shifts"
  echo "$SQL_CONFLICT_HITS" | sed 's/^/   /'
  echo "   -> Remove the predicate and make the DO UPDATE total with a CASE per column. A skipped upsert here rejects a shipped 1.0 build's write"
  echo ""
else
  echo "[PASS] No ON CONFLICT ... WHERE on public.shifts"
fi

# 15b. The Release configuration carries a real Sentry DSN.
#      The failure this catches is silent by construction: with no DSN,
#      PaydayCrashReporting.start() returns immediately and the app ships with
#      crash reporting completely off. That is the correct behaviour for Debug
#      and for CI, and it is indistinguishable from a healthy build, so the one
#      place it must NOT happen -- Release -- needs an assertion rather than a
#      habit. It also pins the DSN to Release: in `settings.base` every local
#      debug run would report into the same project and bury the production
#      signal.
SENTRY_DSN_LINE=$(awk '
  /^      configs:/ { inconf = 1; next }
  /^    [a-z]/ { inconf = 0 }
  inconf && /SENTRY_DSN:/ { print; found = 1 }
  END { if (!found) print "MISSING" }
' project.yml)
if printf '%s' "$SENTRY_DSN_LINE" | grep -qE 'SENTRY_DSN: *https://[0-9a-f]+@[a-z0-9.]+/[0-9]+'; then
  echo "[PASS] Release carries a real Sentry DSN"
elif grep -qE '^ *SENTRY_DSN:' project.yml; then
  FAIL=1
  echo "[FAIL] SENTRY_DSN is present but not a usable DSN on the Release config"
  echo "   got: $SENTRY_DSN_LINE"
  echo "   -> A blank or base-scoped DSN ships with reporting silently OFF, which looks exactly like a healthy build. See docs/SENTRY.md"
  echo ""
else
  FAIL=1
  echo "[FAIL] No SENTRY_DSN in project.yml, so a Release build reports no crashes"
  echo "   -> Add it under the Payday target's settings.configs.Release. See docs/SENTRY.md"
  echo ""
fi

# 15c. THE MONEY BOUNDARY. Outside Packages/PaydayCore, nothing computes money
#      from raw components.
#
#      This is the rule that stops the original problem recurring. The audit
#      did not find missing helpers; it found that the app shared helpers but
#      not the INTERPRETATION, so the same stored shift produced different
#      answers on different screens. Every one of those divergences was a
#      screen doing its own arithmetic on raw fields. Five patterns cover the
#      ones that actually happened:
#
#        .netCents            summed row by row, double-subtracting a
#                             duplicated tip-out on the calendar
#        cashTipsCents +      a total assembled outside the ledger
#        tipOutCents ??       a tip-out defaulted locally instead of read
#                             from a result
#        * 1.5                an overtime multiplier applied by a caller
#        / 100 / hours        an hourly rate derived by a screen
#
#      LANDED BEFORE THE DELETIONS, DELIBERATELY. The allowlist below is the
#      tree as it stands, so the rule exists now and every deletion in PR 8
#      shrinks the list. Written the other way round -- lint after cleanup --
#      it would have been fitted to an already-clean tree and would never have
#      been tested against a real violation.
#
#      THE ALLOWLIST RATCHETS. A file listed here that no longer violates
#      anything is itself a failure, so the list cannot quietly stop
#      shrinking and become permanent permission. That is the whole mechanism.
#
#      It earned its keep on the first run. The allowlist was seeded from a
#      grep that matched COMMENTS as well as code, and the ratchet immediately
#      failed on InsightsEarnings.swift and NightlyEarningsChart.swift because
#      their only matches were comments that the rule strips. Two files that
#      would otherwise have sat in an exemption list they never needed.
MONEY_BOUNDARY_ALLOWLIST="
Payday/Models/TipEntry.swift
Payday/Models/LegacyShiftRow.swift
Payday/Models/ShiftRecord.swift
Payday/Utilities/PaycheckAudit.swift
Payday/Utilities/TipBreakdown.swift
Payday/Utilities/StatsEngine.swift
Payday/Views/Shared/LogTipSheet.swift
"

money_boundary_hits() { # file
  awk '
    {
      line = $0
      # Strip line comments. A doc comment that DESCRIBES the old formula in
      # order to explain why it is gone is not a violation -- StatsEngine
      # documents "Double(cents)/100/hours" for exactly that reason.
      sub(/\/\/.*$/, "", line)
    }
    line ~ /\.netCents/ ||
    line ~ /cashTipsCents[[:space:]]*\+/ ||
    line ~ /tipOutCents[[:space:]]*\?\?/ ||
    line ~ /\*[[:space:]]*1\.5/ ||
    line ~ /\/[[:space:]]*100[[:space:]]*\/[[:space:]]*hours/ {
      printf "%s:%d:%s\n", FILENAME, FNR, line
    }
  ' "$1"
}

MONEY_NEW=""
MONEY_STALE=""
for f in $(find Payday PaydayWidget -name '*.swift' 2>/dev/null | sort); do
  hits=$(money_boundary_hits "$f")
  allowed=$(printf '%s' "$MONEY_BOUNDARY_ALLOWLIST" | grep -Fx "$f" || true)
  if [ -n "$hits" ] && [ -z "$allowed" ]; then
    MONEY_NEW="$MONEY_NEW$hits
"
  fi
done
for f in $(printf '%s' "$MONEY_BOUNDARY_ALLOWLIST" | grep -v '^$'); do
  if [ ! -f "$f" ]; then continue; fi
  if [ -z "$(money_boundary_hits "$f")" ]; then
    MONEY_STALE="$MONEY_STALE   $f
"
  fi
done

if [ -n "$MONEY_NEW" ]; then
  FAIL=1
  echo "[FAIL] Money computed outside PaydayCore"
  printf '%s' "$MONEY_NEW" | grep -v '^$' | sed 's/^/   /'
  echo "   -> Ask the engine for the figure instead. If this file genuinely has to be an adapter, add it to MONEY_BOUNDARY_ALLOWLIST in this script WITH a reason, and expect to be asked why."
  echo ""
elif [ -n "$MONEY_STALE" ]; then
  FAIL=1
  echo "[FAIL] The money-boundary allowlist has entries that no longer violate anything"
  printf '%s' "$MONEY_STALE" | grep -v '^$'
  echo "   -> Delete them from MONEY_BOUNDARY_ALLOWLIST. The list ratchets DOWN; leaving a clean file in it turns a temporary exemption into permanent permission."
  echo ""
else
  echo "[PASS] No money computed outside PaydayCore ($(printf '%s' "$MONEY_BOUNDARY_ALLOWLIST" | grep -cv '^$') file(s) still allowlisted)"
fi

# 16. Every hand-written Codable decoder in PaydaySyncState.swift is complete.
#     A missing line in a hand-written init(from:) that uses decodeIfPresent is
#     a SILENT default, not a throw: the field becomes write-only and always
#     loads as its default. No checkpoint loss, no test failure, nothing in a
#     log. A non-persisting pendingShiftRestores loses an undone shift; a
#     non-persisting cursor re-baselines on every pass. A lint phrased as
#     "fail any Codable with no init(from:)" can never fire on this file.
SNAPSHOT_HITS=$(perl -e '
  my $path = "Payday/Sync/PaydaySyncState.swift";
  open(my $fh, "<", $path) or do { print "$path: cannot open\n"; exit 0 };
  my (@stack, %props, %keys, %decoded, %hasdecoder, @order);
  my ($depth, $cur, $inkeys, $keysdepth, $indecoder, $decoderdepth) = (0, "", 0, 0, 0, 0);
  while (my $line = <$fh>) {
    my $text = $line;
    $text =~ s{//.*$}{};
    if ($text =~ /^\s*(?:(?:private|fileprivate|internal|public|final|static)\s+)*(?:struct|class)\s+(\w+)/) {
      $cur = $1;
      push @order, $cur unless exists $props{$cur};
      $props{$cur} ||= [];
      push @stack, [$cur, $depth];
    } elsif ($cur ne "" && $text =~ /^\s*(?:private\s+)?enum\s+CodingKeys\b/) {
      $inkeys = 1; $keysdepth = $depth;
    } elsif ($cur ne "" && $text =~ /\binit\s*\(\s*from\s+\w+\s*:/) {
      $indecoder = 1; $decoderdepth = $depth; $hasdecoder{$cur} = 1;
    } elsif ($inkeys && $text =~ /^\s*case\s+(.+)$/) {
      my $rest = $1; $rest =~ s/\s//g;
      for my $name (split /,/, $rest) { $name =~ s/=.*$//; $keys{$cur}{$name} = 1 if $name =~ /^\w+$/; }
    } elsif ($indecoder && $text =~ /forKey:\s*\.(\w+)/) {
      $decoded{$cur}{$1} = 1;
    } elsif ($cur ne "" && !$inkeys && !$indecoder && $depth == $stack[-1][1] + 1
             && $text =~ /^\s*(?:(?:private|fileprivate|internal|public)\s+)?(?:var|let)\s+(\w+)\s*(:[^={]*)?(=|\{\s*didSet|$|\s*$)/) {
      my ($name, $tail) = ($1, $3);
      next if $text =~ /\{\s*(get|$)/ && $text !~ /didSet/;
      push @{ $props{$cur} }, $name;
    }
    my $open = ($text =~ tr/{//); my $close = ($text =~ tr/}//);
    $depth += $open - $close;
    if ($inkeys && $depth <= $keysdepth) { $inkeys = 0; }
    if ($indecoder && $depth <= $decoderdepth) { $indecoder = 0; }
    while (@stack && $depth <= $stack[-1][1]) { pop @stack; $cur = @stack ? $stack[-1][0] : ""; }
  }
  close $fh;
  for my $type (@order) {
    next unless $hasdecoder{$type};
    for my $name (@{ $props{$type} }) {
      print "$path: $type.$name is a stored property with no CodingKeys case\n" unless $keys{$type}{$name};
      print "$path: $type.$name is never assigned in init(from:)\n" unless $decoded{$type}{$name};
    }
  }
' 2>/dev/null || true)
if [ -n "$SNAPSHOT_HITS" ]; then
  FAIL=1
  echo "[FAIL] A hand-written Codable in PaydaySyncState.swift is missing a key"
  echo "$SNAPSHOT_HITS" | sed 's/^/   /'
  echo "   -> Add the CodingKeys case AND the decodeIfPresent line. A missing line loads as the default with no throw and no test failure"
  echo ""
else
  echo "[PASS] Every hand-written Codable in PaydaySyncState.swift decodes every stored property"
fi

# 17. Single-definition pins.
#     Each of these is a fact that must have exactly one implementation,
#     because a second one compiles cleanly and then disagrees:
#
#     shiftsAreAuthoritative — the reader's switch. The widget, both App
#       Intents and the app all call it. A second definition (the tempting one
#       is a fresh bool on AppGroup, which IS in the widget's sources and so
#       would compile) leaves the Lock Screen printing pre-conversion numbers
#       while the app prints post-conversion ones.
#     recordTipDeletions — the durable deletion queue. A second writer is a
#       deletion that reaches one queue and not the other.
#     shiftCacheRequiresBaseline — the wiped-shift-cache detector of 7.4. The
#       device may never derive a shift, so this fact decides whether a forced
#       server baseline runs, and 7.2/7.3 make the Snapshot checkpoint its one
#       durable store. S1 briefly implemented a second copy on standalone
#       UserDefaults keys; the reader can then consult one copy while the sync
#       leg clears the other, and only the checkpoint copy survives the
#       measured downgrade purge for an account with no legacy rows at all.
#     payday_shift_rollback_at — the rollback stamp every reader consults.
#
#     "At most one" rather than "exactly one": shiftsAreAuthoritative and
#     shiftCacheRequiresBaseline land in S7 and payday_shift_rollback_at in
#     S5, so zero is legal until then.
pin_check() {
  local name="$1" pattern="$2"; shift 2
  local count
  count=$(grep -rn -E "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt 1 ]; then
    FAIL=1
    echo "[FAIL] $name has $count definitions; it may have at most one"
    grep -rn -E "$pattern" "$@" 2>/dev/null | sed 's/^/   /'
    echo ""
  else
    echo "[PASS] $name has $count definition(s)"
  fi
}

pin_check "shiftsAreAuthoritative" 'func +shiftsAreAuthoritative\b' Payday PaydayWidget --include=*.swift
pin_check "recordTipDeletions" 'func +recordTipDeletions\b' Payday PaydayWidget --include=*.swift
pin_check "shiftCacheRequiresBaseline" 'func +shiftCacheRequiresBaseline\b' Payday PaydayWidget --include=*.swift
pin_check "payday_shift_rollback_at" 'create +(or +replace +)?function +[a-z_.]*payday_shift_rollback_at' supabase --include=*.sql

# 18. No silent save in a view. Every SwiftUI write path goes through
#     ShiftCommands.commit, which saves ONCE and rolls back on any throw.
#
#     `try? context.save()` was the shipped idiom, and with
#     `autosaveEnabled = false` it became actively dangerous rather than
#     merely sloppy: the mutation is discarded and nothing says so. Two live
#     bugs came from exactly this and are fixed in S9's second half.
#
#     UndoDeleteToast.delete recorded the server-side deletion BEFORE its
#     `try? save()`, so a failed save left the rows on screen with their ids
#     already in the App Group's pending-deletion queue. The next sync then
#     deleted, on the server, rows the user could still see: the app and the
#     server disagreeing about whether that money exists, which is the one
#     thing this project is for.
#
#     ShiftContextMenu's duplicate fired PaydayHaptics.medium() unconditionally
#     after its `try? save()`, so a failed duplicate buzzed success and
#     produced nothing.
#
#     Scoped to Payday/Views. Payday/Debug/DebugSeeder.swift keeps its six,
#     deliberately: it is debug-only seed data, it is not a user's money, and
#     a seeding failure is meant to be loud in the console rather than
#     recovered.
SILENT_SAVE=$(grep -rn -E 'try\? +[A-Za-z_.]*\.save\(\)' Payday/Views --include=*.swift 2>/dev/null | grep -v '^\s*//' | grep -vE '^[^:]+:[0-9]+: *(///|//)')
if [ -n "$SILENT_SAVE" ]; then
  FAIL=1
  echo "[FAIL] A view saves with try?, discarding the error silently"
  printf '%s\n' "$SILENT_SAVE" | sed 's/^/   /'
  echo "   -> Wrap the mutation in ShiftCommands.commit(in:) and act on the throw."
  echo "      A failed save must not leave a queued server deletion, a success"
  echo "      haptic, or a dismissed toast behind it."
  echo ""
else
  echo "[PASS] No view saves with try? (every write path goes through the commit boundary)"
fi

# 19. Every production reader of the engine passes shiftsAreAuthoritative.
#     A bug class no test can catch, because the argument is DEFAULTED: omit
#     it and the code compiles, every test still passes, and the behaviour
#     silently reverts to the pre-conversion rule.
#
#     That is exactly what happened. `EarningsStore.init` documents "S7 passes
#     its single shiftsAreAuthoritative in here" and S7 shipped without doing
#     it, so all three production call sites -- PaydayApp, AmbientPeriodFigure
#     (the one function the widget AND Siri share) and PaydayWidget -- kept the
#     pre-S7 default of `false`, and `.shiftCacheWiped` was unreachable in the
#     shipped app. Only the tests ever passed `true`, so the mechanism was
#     covered while the product could not reach it.
#
#     The consequence was not cosmetic. `ModelContextEarningsInputSource
#     .fetchInputs` reads shifts from `ShiftRecord` ONLY and counts TipEntry
#     purely as `legacyTipEntryCount`, which exists solely to feed this check.
#     So a converted account whose shift cache was purged computed from zero
#     shifts while that count knew the data was still there, and the app, the
#     Lock Screen and Siri all rendered $0.
#
#     Balances parentheses rather than grepping a line, because all three call
#     sites span several lines and a line-oriented grep would pass them all.
AUTHORITATIVE_OMISSIONS=$(perl -e '
  use strict; use warnings; use File::Find;
  my @files; my @hits;
  find(sub { push @files, $File::Find::name if /\.swift$/ }, "Payday", "PaydayWidget");
  for my $f (sort @files) {
    open(my $fh, "<", $f) or next;
    local $/; my $src = <$fh>; close $fh;
    $src =~ s{/\*.*?\*/}{}gs;
    $src =~ s{//[^\n]*}{}g;
    while ($src =~ /\bEarningsStore(?:\.buildOnce)?\s*\(/g) {
      my $start = pos($src) - 1;
      my ($depth, $i, $len) = (0, $start, length($src));
      while ($i < $len) {
        my $c = substr($src, $i, 1);
        $depth++ if $c eq "(";
        $depth-- if $c eq ")";
        last if $depth == 0;
        $i++;
      }
      my $call = substr($src, $start, $i - $start + 1);
      next if $call =~ /shiftsAreAuthoritative\s*:/;
      my $line = 1 + (() = substr($src, 0, $start) =~ /\n/g);
      push @hits, "$f:$line";
    }
  }
  print "$_\n" for @hits;
')
if [ -n "$AUTHORITATIVE_OMISSIONS" ]; then
  FAIL=1
  echo "[FAIL] An engine reader omits shiftsAreAuthoritative, so it silently uses the pre-conversion rule"
  printf '%s\n' "$AUTHORITATIVE_OMISSIONS" | sed 's/^/   /'
  echo "   -> Pass shiftsAreAuthoritative: PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount."
  echo "      Omitting it defaults to false, which makes .shiftCacheWiped unreachable"
  echo "      and renders \$0 for a converted account whose shift cache was purged."
  echo ""
else
  echo "[PASS] Every engine reader passes shiftsAreAuthoritative"
fi

# 20. A deletion is never queued for the server from INSIDE a transaction.
#     The misconception this closes was written into the tree as a claim of
#     safety. LogTipSheet.delete called recordTipDeletions inside a
#     ShiftCommands.commit body under the comment "Queued and deleted
#     together, so the server cannot be told about a deletion the device then
#     fails to make, or the reverse."
#
#     Co-locating them does not achieve that and cannot. The pending-deletion
#     queue is App Group UserDefaults -- recordTipDeletions ends in
#     AppGroup.defaults.set, which takes effect at once -- while the rows are
#     SwiftData. context.rollback() restores the rows and has no reach into
#     the queue. So the shipped shape put the rows back on the device and left
#     their ids queued for server-side deletion: the next sync removed money
#     the user could still see. On the pruneZeroedRows path the enclosing
#     `try?` meant nothing was reported either.
#
#     Asserted from the other direction in DeletionQueueAtomicityTests
#     (rollbackDoesNotUndoTheQueueWrite): that test says the queue is not
#     transactional, this rule says no call site may assume otherwise.
#
#     The checker lives in its own file rather than inline. An earlier draft
#     embedded the perl in a shell string, the quoting mangled it, and it
#     printed "[PASS]" while perl reported "Execution of -e aborted due to
#     compilation errors" -- because an empty result from a BROKEN checker is
#     indistinguishable from a clean one. Hence the exit-status check below:
#     a checker that cannot run is a failure, never a pass.
QUEUE_IN_TXN=$(perl scripts/lint-queue-in-transaction.pl 2>&1)
QUEUE_IN_TXN_STATUS=$?
if [ "$QUEUE_IN_TXN_STATUS" -ne 0 ]; then
  FAIL=1
  echo "[FAIL] rule 20's checker could not run, so the rule proved nothing"
  printf '%s\n' "$QUEUE_IN_TXN" | sed 's/^/   /'
  echo ""
elif [ -n "$QUEUE_IN_TXN" ]; then
  FAIL=1
  echo "[FAIL] A deletion is queued for the server from inside a transaction"
  printf '%s\n' "$QUEUE_IN_TXN" | sed 's/^/   /'
  echo "   -> Move the record/cancel call AFTER the commit returns. A rollback"
  echo "      restores the rows and does NOT unqueue the deletion, so a failed"
  echo "      save would leave the server deleting a row the user still has."
  echo ""
else
  echo "[PASS] No deletion is queued from inside a transaction"
fi

# 21. The device's time zone cannot reach the earnings path, except at the
#     three sites that freeze it or precede any policy.
#
#     A frozen payroll zone is a T1 guarantee: a device that travels must not
#     re-date a shift into another week or another pay period.
#     `PolicyStore` line ~335 freezes the device zone INTO a calendar policy
#     at migration, so after that `calendars` is non-empty and the `?? .current`
#     fallbacks are unreachable. The property holds.
#
#     What did not hold is the ENFORCEMENT. `EarningsStore` carried the comment
#     "`TimeZone.current` appears nowhere in this file" three lines above
#     `policies.payrollTimeZone ?? .current`. Literally true about that exact
#     string, false about the property it was asserting -- the same shape as
#     `LegacySnapshotBridge`'s tip-out comment claiming to preserve a
#     distinction its own input had already destroyed. A comment was doing a
#     lint's job, so nothing stopped a fourth fallback appearing.
#
#     Counted per file rather than merely named, so a SECOND fallback inside
#     an already-allowlisted file still fails. Proven both ways: adding one to
#     `LegacySnapshotBridge` (allowlisted for 0) fails, and adding a second to
#     `ShiftInputAdapter` (allowlisted for 1) fails.
#
#     The list ratchets DOWN. When `ShiftDraftPreview` moves off
#     `Calendar.current`, lower its number; do not leave slack.
DEVICE_ZONE=$(perl scripts/lint-device-zone.pl 2>&1)
DEVICE_ZONE_STATUS=$?
if [ "$DEVICE_ZONE_STATUS" -ne 0 ]; then
  FAIL=1
  echo "[FAIL] rule 21's checker could not run, so the rule proved nothing"
  printf '%s\n' "$DEVICE_ZONE" | sed 's/^/   /'
  echo ""
elif [ -n "$DEVICE_ZONE" ]; then
  FAIL=1
  echo "[FAIL] The device time zone reaches the earnings path somewhere new"
  printf '%s\n' "$DEVICE_ZONE" | sed 's/^/   /'
  echo "   -> Money must be dated by the FROZEN payroll zone, or a user who"
  echo "      travels re-dates their own history. If the site is genuinely a"
  echo "      pre-policy first launch, raise its count in"
  echo "      scripts/lint-device-zone.pl and say why."
  echo ""
else
  echo "[PASS] The device time zone reaches the earnings path only where allowlisted"
fi

# 22. Rule 20 proves itself against the WHOLE queue-symbol family.
#
#     "A guard narrower than the family it guards" happened three times in one
#     day: rule 20 knew only `record|cancelTipDeletions` and was blind to the
#     shift, legacy-entry and paycheck queues, which is how a fourth site in
#     `PaycheckEntrySheet` survived; rule 21 nearly caught only
#     `TimeZone.current` and would have missed the bare `.current` that
#     motivated it; and a release-gate grep searched a directory the mechanism
#     does not live in. So the standing fix is a discipline rather than another
#     widening: a lint that has never been shown to catch every shape it claims
#     to is a lint trusted on faith.
#
#     `lint-selftest-queue.sh` plants one instance of each of the 14
#     `PaydaySyncState` queue mutators inside a `commit` body and asserts rule
#     20 reports every one. It also plants each of them AFTER the commit and
#     asserts none is reported, so the rule is shown to discriminate on
#     POSITION rather than on mere presence -- a rule that fires on everything
#     is as useless as one that fires on nothing.
#
#     Proven to work: narrowing the checker back to its original tip-only form
#     makes the self-test report 12 misses and fail.
QUEUE_SELFTEST=$(bash scripts/lint-selftest-queue.sh 2>&1)
QUEUE_SELFTEST_STATUS=$?
if [ "$QUEUE_SELFTEST_STATUS" -ne 0 ]; then
  FAIL=1
  echo "[FAIL] rule 20 does not catch every queue symbol it claims to"
  printf '%s\n' "$QUEUE_SELFTEST" | sed 's/^/   /'
  echo ""
else
  echo "[PASS] rule 20 proves itself against all 14 queue symbols, positive and negative"
fi

# --- Rule 23: no app-code call reads the legacy shift representation alone.
#
#     The flip gives Payday two stored shapes for the same shift, and for as
#     long as both exist a reader can be pointed at the wrong one. The cost of
#     getting that wrong is not a wrong total -- each surface stays perfectly
#     self-consistent with whatever it read, which is why every parity gate in
#     the suite stayed green through EIGHT of these. It is two surfaces
#     disagreeing about one fact, which is the entire thing PaydayCore exists
#     to end.
#
#     The primary enforcement is the type system: the combined builders take
#     BOTH lists and resolve the representation internally, so a legacy-only
#     call does not compile and the COMPILER enumerates the call sites. This
#     rule is the backstop for what the compiler cannot see -- a NEW
#     legacy-only builder added later, which has no missing parameter to
#     object to.
#
#     Per-call-site, not per-file, and that distinction was paid for. The
#     first draft asked whether a FILE mentioning the legacy list also
#     mentioned the predicate. It was silent on `DeleteAccountSheet`'s CSV
#     export -- the worst defect of the eight, a permanently short export
#     offered directly above the delete button -- because the same file
#     mentioned the predicate for an unrelated shift count three lines away.
#     And it flagged `DayDetailSheet`, which was correct all along. "The file
#     has a switch in it" is not evidence that a given read is switched.
#
#     SCOPE, and this was wrong when the rule was written: it ran against
#     `Payday` alone, so the WIDGET -- a separate target that reads the same
#     App Group store and shows its own money -- was never checked by the
#     rule written to prevent exactly that class of miss. Found by running it
#     against `PaydayWidget` by hand, which turned up the pace baseline
#     reading `allEntries` directly. That is the same narrower-than-the-family
#     error rule 20 already paid for (it knew only the tip queues and was
#     blind to three others), repeated inside the rule meant to end it. It now
#     takes "${SRC[@]}", the same roots every other rule uses, so the scope
#     cannot drift from the rest of the script again.
REPRESENTATION=$(perl scripts/lint-representation-switch.pl "${SRC[@]}" 2>&1)
REPRESENTATION_STATUS=$?
if [ "$REPRESENTATION_STATUS" -ne 0 ]; then
  FAIL=1
  echo "[FAIL] a reader takes its shifts from the legacy representation alone"
  printf '%s\n' "$REPRESENTATION" | sed 's/^/   /'
  echo ""
else
  echo "[PASS] every app-code shift read hands over both representations"
fi

# --- Rule 24: rule 23 proves itself.
#
#     Same discipline as rule 22, and for the same reason: a lint that has
#     never been shown to catch every shape it claims to is a lint trusted on
#     faith. The self-test plants all eight real defect shapes the sweep found
#     plus a hypothetical future legacy-only builder, and asserts rule 23
#     reports each. It also plants the six shapes that must NOT fire -- a
#     switched call, a declaration, a doc comment, a block comment, a tuple
#     whose label happens to be `entries`, and a resolution marked as made
#     upstream -- so the rule is shown to DISCRIMINATE rather than merely to
#     fire.
#
#     It also proves the rule's ROOTS, which is a separate thing from its
#     pattern and the one that actually bit. Rule 23 shipped scoped to
#     `Payday` alone, so `PaydayWidget` -- a separate target opening the same
#     App Group store and rendering its own money -- was unchecked by the lint
#     written to prevent that class of miss, and gap 9 was found there by
#     hand. The self-test now asserts the INVOCATION passes "${SRC[@]}".
#
#     That distinction was itself paid for: the first version planted a
#     violation in each root but invoked the perl script directly with all of
#     them, which proved the SCRIPT could scan a root rather than that
#     design-lint TELLS it to -- and it passed while the invocation was
#     re-narrowed to `Payday`. A check inventing its own answer, for the third
#     time in this engagement and the second inside this rule's own test.
#
#     Proven to work, both halves: stubbing rule 23's reporting branch makes
#     the self-test report 9 misses and fail; re-narrowing the invocation to
#     `Payday` makes it fail with "MISS (scope)".
REPRESENTATION_SELFTEST=$(bash scripts/lint-selftest-representation.sh 2>&1)
REPRESENTATION_SELFTEST_STATUS=$?
if [ "$REPRESENTATION_SELFTEST_STATUS" -ne 0 ]; then
  FAIL=1
  echo "[FAIL] rule 23 does not catch every representation shape it claims to"
  printf '%s\n' "$REPRESENTATION_SELFTEST" | sed 's/^/   /'
  echo ""
else
  printf '[PASS] %s\n' "$REPRESENTATION_SELFTEST"
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
  echo "=== Design lint FAILED — see docs/DESIGN.md ==="
  exit 1
fi
# 32. Parsers produce candidates, never rows.
#     A parser's output is a GUESS -- from OCR or a model -- and the design
#     is that a person confirms it before it becomes money. A parser that
#     writes has removed the confirmation step without anyone deciding to,
#     and the failure is silent: the shift appears, already wrong,
#     attributed to the user. PR 7's last unenforced item.
if bash scripts/lint-parsers-pure.sh; then :; else FAIL=1; fi

# 33. A PaydaySyncState accessor with no production reader is a defect.
#     Four instances of this shape have been found by hand here -- the
#     conversion banner with no producer, `conversionPending` never
#     assigned, EarningsStore registrations never asserted, and the shift
#     deletion queues with no consumer. The last is a latent P0 and was
#     found by accident. The allowlist must DRAIN: each entry names a marker
#     that has to exist in RELEASE_GATE.md, and an entry that gains a reader
#     fails too.
if bash scripts/lint-syncstate-wired.sh; then :; else FAIL=1; fi

# 31. A gate document may not cite a symbol that does not exist.
#     RELEASE_GATE.md cited a test name that was a hand-camel-cased display
#     string. The coverage was real; the identifier was not, and a reviewer
#     grepping it concluded the opposite. Delegated to its own script because
#     it searches the whole tree rather than the comment-blanked stream.
if bash scripts/lint-doc-citations.sh; then :; else FAIL=1; fi

echo "=== Design lint passed ==="
