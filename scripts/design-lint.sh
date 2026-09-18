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

echo ""
if [ "$FAIL" -eq 1 ]; then
  echo "=== Design lint FAILED — see docs/DESIGN.md ==="
  exit 1
fi
echo "=== Design lint passed ==="
