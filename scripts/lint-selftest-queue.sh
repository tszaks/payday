#!/bin/bash
# Proves rule 20 fires on EVERY member of the queue-symbol family, by planting
# one instance of each and checking the rule reports it.
#
# Written because "a guard narrower than the family it guards" happened three
# times in one day: rule 20 knew only `record|cancelTipDeletions` and was blind
# to the shift, legacy-entry and paycheck queues; rule 21 nearly caught only
# `TimeZone.current` and would have missed the bare `.current` that motivated
# it; and a release-gate grep searched a directory the mechanism does not live
# in. A lint never shown to catch every shape it claims to is a lint trusted on
# faith.
set -u
CHECKER="$(cd "$(dirname "$0")" && pwd)/lint-queue-in-transaction.pl"
FAIL=0

SYMBOLS=(
  recordTipDeletions cancelTipDeletions clearTipDeletions
  recordShiftDeletion clearShiftDeletions
  recordShiftRestore clearShiftRestores
  clearShiftTombstones markShiftTombstonesFlushed
  recordLegacyEntryDeletions cancelLegacyEntryDeletions clearLegacyEntryDeletions
  recordPaycheckDeletion clearPaycheckDeletions
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

plant() { # $1 symbol, $2 inside|outside
  local dir="$tmp/$2/$1/Payday"
  mkdir -p "$dir"
  if [ "$2" = inside ]; then
    cat > "$dir/Planted.swift" <<EOF
func planted(_ context: ModelContext) throws {
    try ShiftCommands.commit(in: context) {
        PaydaySyncState.$1([UUID()])
        context.delete(thing)
    }
}
EOF
  else
    cat > "$dir/Planted.swift" <<EOF
func planted(_ context: ModelContext) throws {
    try ShiftCommands.commit(in: context) {
        context.delete(thing)
    }
    PaydaySyncState.$1([UUID()])
}
EOF
  fi
  echo "$tmp/$2/$1"
}

echo "--- positive: the rule must report every symbol planted INSIDE a commit body"
for sym in "${SYMBOLS[@]}"; do
  root=$(plant "$sym" inside)
  out=$(cd "$root" && perl "$CHECKER" Payday 2>&1)
  if [ -z "$out" ]; then
    echo "   MISS: $sym planted inside a commit body was NOT reported"
    FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] && echo "   all ${#SYMBOLS[@]} symbols reported"

echo "--- negative: the rule must NOT report the same symbol placed AFTER the commit"
NEG=0
for sym in "${SYMBOLS[@]}"; do
  root=$(plant "$sym" outside)
  out=$(cd "$root" && perl "$CHECKER" Payday 2>&1)
  if [ -n "$out" ]; then
    echo "   FALSE POSITIVE: $sym placed after the commit was reported"
    FAIL=1; NEG=1
  fi
done
[ "$NEG" -eq 0 ] && echo "   none reported, so the rule distinguishes position and not merely presence"

if [ "$FAIL" -ne 0 ]; then
  echo "SELFTEST FAILED"
  exit 1
fi
echo "SELFTEST PASSED"
