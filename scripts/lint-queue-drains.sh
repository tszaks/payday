#!/usr/bin/env bash
# 34. A durable queue that `synchronize` FLUSHES must also be DRAINED there.
#
# This rule exists because the same defect was shipped three times in one
# day, each time found only by the next round of review:
#
#   #102  the legacy-entry deletion queue had a live producer and no reader
#   #103  the shift deletion queue was flushed and never cleared
#   #104  the shift restore queue was flushed and never cleared
#
# Every one is the same shape. A queue is written by a user action, read and
# flushed by the sync, and cleared ONLY on the undo path -- so it re-sends
# its entire history on every later pass, forever, and nothing fails. The
# generating decision is that the flush and the clear are hand-written at
# two distant sites in `synchronize` with no structural link, so a half
# written pair is silent.
#
# The rule: if `synchronize` reads `pendingFoo`, it must also call `clearFoo`
# somewhere in the same function. Naming is regular across all five queues:
# pending<X> pairs with clear<X>.
set -uo pipefail

SVC=Payday/Sync/PaydaySyncService.swift
STATE=Payday/Sync/PaydaySyncState.swift
FAIL=0

# the body of synchronize: from its signature to the end of the file is too
# coarse, so bound it at the next top-level `    func ` / `    static func `.
BODY=$(awk '
  /^    func synchronize\(/ { inside=1 }
  inside { print }
  inside && /^    \}$/ { exit }
' "$SVC")

[ -z "$BODY" ] && { echo "[FAIL] rule 34 could not locate synchronize() in $SVC"; exit 1; }

# Flattened, because a real call wraps:
#     PaydaySyncState.clearShiftRestores(
#         checkpoint.pendingShiftRestores.keys, for: userID)
# and a line-based grep cannot see an argument on the next line. The first
# draft of this check reported that call missing -- a false POSITIVE on
# correct code, which is how a lint gets switched off.
FLAT=$(printf '%s' "$BODY" | tr '\n' ' ')

for accessor in $(grep -oE "static func pending[A-Za-z]+\(" "$STATE" \
                  | sed -E 's/static func (pending[A-Za-z]+)\(/\1/' | sort -u); do
  printf '%s' "$BODY" | grep -q "\b$accessor\b" || continue
  drain="clear${accessor#pending}"
  # NOT a bare name check. `synchronize` already calls `clearShiftDeletions`
  # on the UNDO path with `restoredShiftIDs`, so presence of the name is
  # satisfied by a call that drains nothing -- and the first draft of this
  # lint passed with #103's bug reintroduced for exactly that reason. The
  # drain must be called with the QUEUE's own keys, so require an argument
  # derived from a `pending...` value.
  if ! printf '%s' "$FLAT" | grep -qE "$drain\([^)]*pending"; then
    echo "[FAIL] synchronize() flushes '$accessor' but never calls '$drain'"
    echo "   -> The queue re-sends its whole history on every later pass."
    echo "      Clear it after the write returns, not on the undo path only."
    FAIL=1
  fi
done

[ "$FAIL" = "1" ] && { echo "=== queue-drain lint FAILED ==="; exit 1; }
echo "[PASS] every durable queue synchronize() flushes is also drained there"
