#!/bin/bash
# Proves rule 23 catches every shape it claims to, and does NOT fire on the
# shapes it must leave alone.
#
# The standing discipline this file answers, from design-lint.sh's own notes:
# "a lint that has never been shown to catch every shape it claims to is a
# lint trusted on faith." Rule 23 earns that scrutiny more than most, because
# its first draft was a per-FILE check that failed in both directions on real
# code -- silent on the CSV export because the same file mentioned the
# predicate for an unrelated count, and noisy on `DayDetailSheet`, which was
# correct. Both of those are negative cases below.
#
# The positives are the eight real defects the sweep actually found, reduced
# to their call shape. Each is planted in a scratch file and the rule must
# report it. The negatives are the shapes that were correct all along.

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Payday/Views"

fail=0

# ---------------------------------------------------------------- positives
# Each entry: name, then the Swift text whose legacy-only read must be caught.
plant_positive() {
  local name="$1" body="$2"
  printf '%s\n' "$body" > "$TMP/Payday/Views/Case.swift"
  local out
  out=$(cd "$TMP" && perl "$REPO/scripts/lint-representation-switch.pl" Payday 2>&1)
  if [ -z "$out" ]; then
    echo "MISS (rule stayed silent): $name"
    fail=1
  fi
}

# ---------------------------------------------------------------- negatives
plant_negative() {
  local name="$1" body="$2"
  printf '%s\n' "$body" > "$TMP/Payday/Views/Case.swift"
  local out
  out=$(cd "$TMP" && perl "$REPO/scripts/lint-representation-switch.pl" Payday 2>&1)
  if [ -n "$out" ]; then
    echo "FALSE POSITIVE: $name"
    echo "   $out"
    fail=1
  fi
}

# 1. PeriodsView: the History list on the legacy rows while its detail read
#    records. The audit's original criterion-5 defect.
plant_positive "gap 1 PeriodsView" 'func f() {
    return HistoryEarnings.build(
        entries: allEntries,
        policies: policies,
        payrollTimeZone: zone
    )
}'

# 2. DeleteAccountSheet: the shift COUNT on a deletion confirmation.
plant_positive "gap 2 legacy grouping for a count" 'func f() -> Int {
    ShiftDays.groupedByShift(entries: allEntries, shiftID: 1).count
}'

# 3. InsightsView.
plant_positive "gap 4 InsightsView" 'func f() {
    let d = InsightsEarnings.build(
        entries: allEntries,
        policies: p,
        payrollTimeZone: z,
        calendar: c
    )
}'

# 4. PaydayPushScheduler: the figure the payday push SPEAKS.
plant_positive "gap 5 push scheduler" 'func f() {
    let s = DashboardEarnings.build(
        entries: allEntries,
        policies: policies,
        payrollTimeZone: payrollTimeZone,
        calendar: cal
    ).snapshot
}'

# 5. CSVExporter: the export offered above the delete button. The worst one.
plant_positive "gap 6 CSV export" 'func f() {
    CSVExporter.export(
        entries: allEntries,
        paycheckRecords: paycheckRecords,
        calculator: calculator
    )
}'

# 6. CalendarView: the month grid.
plant_positive "gap 7 calendar month grid" 'func f() {
    CalendarEarnings.snapshot(
        shifts: CalendarEarnings.shiftGroups(entries: allEntries, payrollTimeZone: zone),
        policies: p,
        payrollTimeZone: zone
    )
}'

# 7. LogTipSheet: the reveal comparison's history.
plant_positive "gap 8 reveal history" 'func f() {
    ShiftDraftPreview.snapshot(
        draft: d,
        entries: allEntries,
        policies: p,
        payrollTimeZone: z,
        windowed: false
    )
}'

# 8. A NEW builder nobody has written yet, legacy-only. This is the case the
#    compiler cannot object to -- there is nothing missing from a signature
#    that never had it -- and therefore the whole reason this rule exists
#    alongside the type change.
plant_positive "a future legacy-only builder" 'func f() {
    SomeNewScreenEarnings.build(entries: allEntries, policies: p)
}'

# ---- negatives ----

# A switched call: both representations handed over.
plant_negative "switched call" 'func f() {
    HistoryEarnings.build(
        entries: allEntries,
        records: shiftRecords,
        policies: policies,
        payrollTimeZone: zone
    )
}'

# A DECLARATION, not a call. The builders own parameter lists must not trip it.
plant_negative "a declaration" 'enum E {
    static func build(
        entries: [TipEntry],
        policies: CompensationPolicies
    ) -> Build {
        Build()
    }
}'

# Prose. `LegacySnapshotRevision` documents a legacy spelling in a doc comment
# and was reported as a violation by the first draft.
plant_negative "a doc comment" '/// MEASURED: `LegacySnapshotBridge.snapshot(entries:)` costs 41.7 ms.
/// See also `HistoryEarnings.build(entries:)`.
func f() {}'

# A block comment, same shape.
plant_negative "a block comment" '/*
 CSVExporter.export(entries: allEntries, paycheckRecords: r, calculator: c)
*/
func f() {}'

# The tuple whose label happens to be `entries`.
plant_negative "a tuple label" 'func f() {
    let pairs = things.map { (shiftID: id, entries: entries) }
}'

# A resolution made upstream and marked at the call.
plant_negative "marked resolved upstream" 'func f() {
    // lint:representation-resolved-upstream
    DashboardEarnings.build(
        entries: allEntries,
        policies: policies,
        payrollTimeZone: zone,
        calendar: cal
    )
}'

# ------------------------------------------------------- the rule's own teeth
# A rule that fires on everything is as useless as one that fires on nothing,
# so prove the marker is NARROW: the same call without the marker must fire.
plant_positive "unmarked twin of the marked case" 'func f() {
    DashboardEarnings.build(
        entries: allEntries,
        policies: policies,
        payrollTimeZone: zone,
        calendar: cal
    )
}'

# ------------------------------------------------- the rule's ROOTS have teeth
# A rule's roots are as much a part of it as its pattern.
#
# Everything above plants violations in ONE directory, so it proved the rule
# catches every SHAPE -- and it would have passed happily while the rule was
# blind to an entire TARGET. That is not hypothetical: rule 23 shipped scoped
# to `Payday` alone, leaving `PaydayWidget` -- a separate target that opens the
# same App Group store and renders its own money -- completely unchecked by
# the lint written to prevent exactly that class of miss. Gap 9 (the widget's
# pace baseline reading `TipEntry` directly) was found by running the rule
# against that root BY HAND.
#
# So this section plants one instance in EVERY root design-lint passes, and
# asserts the rule reports each one. A future narrowing of the scope now fails
# the build instead of waiting to be noticed.
#
# The roots are read out of design-lint.sh rather than restated here, because
# a hand-copied list is the same drift problem one level up: the two would
# diverge and this test would go back to proving less than it claims.
ROOTS=$(sed -n 's/^SRC=(\(.*\))$/\1/p' "$REPO/scripts/design-lint.sh")

# FIRST, and this is the check that actually catches gap 9's root cause.
#
# The per-root planting below invokes the perl script with every root
# directly, so it proves the SCRIPT can scan a root when told to. It does NOT
# prove design-lint TELLS it to -- and that was the whole defect: the script
# was always capable, and the invocation passed `Payday` alone.
#
# Measured: with the invocation re-narrowed to `Payday`, the per-root section
# below still passed. So that section, on its own, is another check inventing
# its own answer -- the third instance of that family in this engagement, and
# the second inside this rule's own test. This line is the one with teeth.
INVOCATION=$(grep -n 'lint-representation-switch\.pl' "$REPO/scripts/design-lint.sh" \
  | grep -v '^\s*#' | grep 'REPRESENTATION=')
if ! printf '%s' "$INVOCATION" | grep -q '"\${SRC\[@\]}"'; then
  echo "MISS (scope): design-lint does not pass \"\${SRC[@]}\" to rule 23."
  echo "   found: $INVOCATION"
  echo "   A hardcoded root list is how the widget target went unchecked (gap 9)."
  fail=1
fi

if [ -z "$ROOTS" ]; then
  echo "MISS: could not read SRC=(...) from design-lint.sh, so the roots are unproven"
  fail=1
else
  for root in $ROOTS; do
    ROOT_TMP=$(mktemp -d)
    mkdir -p "$ROOT_TMP/$root/Nested"
    # A legacy-only builder call, the plainest shape the rule exists to catch.
    printf '%s\n' 'func f() { SomeEarnings.build(entries: allEntries, policies: p) }' \
      > "$ROOT_TMP/$root/Nested/RootProbe.swift"
    out=$(cd "$ROOT_TMP" && perl "$REPO/scripts/lint-representation-switch.pl" $ROOTS 2>&1)
    if [ -z "$out" ]; then
      echo "MISS (root not covered): a violation in '$root' was not reported"
      fail=1
    fi
    rm -rf "$ROOT_TMP"
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "rule 23 self-test FAILED"
  exit 1
fi
echo "rule 23 proves itself: 9 defect shapes caught, 6 correct shapes left alone, every root covered"
exit 0
