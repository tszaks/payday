#!/usr/bin/env bash
# A PaydaySyncState accessor with no production reader is a defect.
#
# Four instances of this shape have been found by hand in this project:
# the conversion banner with no producer, `conversionPending` never
# assigned, EarningsStore registrations never asserted, and the shift
# deletion queues with no consumer. The fourth is a latent P0 -- a deleted
# shift returns after the flip -- and it was found by accident while
# sweeping something else. Four is past coincidence.
#
# The rule is crude on purpose: production code that writes a value nobody
# reads is either dead or unfinished, and both need saying out loud.
#
# THE ALLOWLIST MUST DRAIN. Each entry names a MARKER that has to appear in
# docs/RELEASE_GATE.md. When the condition is resolved and its section
# leaves the doc, every entry naming it FAILS and must be removed or
# re-justified. An entry whose symbol has gained a reader also fails. So the
# list cannot outlive its reason in either direction -- which is the
# difference between an allowlist and a suppression file.
set -uo pipefail

STATE=Payday/Sync/PaydaySyncState.swift
GATE=docs/RELEASE_GATE.md
LIST=scripts/syncstate-unwired-allowlist.txt
FAIL=0

# A moved or renamed input leaves every loop below with nothing to read, and
# a lint that reads nothing passes.
for input in "$STATE" "$GATE" "$LIST"; do
  [ -f "$input" ] || { echo "[FAIL] $input is missing, so the wiring lint has nothing to check"; exit 1; }
done

# Production readers of one accessor, comments stripped. Outside $STATE a
# reader names it as `PaydaySyncState.<symbol>`; inside $STATE only a call
# counts. A bare name match would count the file's own stored fields of the
# same name -- `pending.shiftTombstones[id] = ...` -- as reads, and pass an
# accessor that nothing calls.
readers() {
  local sym=$1 outside inside
  outside=$(grep -rE "PaydaySyncState\.${sym}\b" Payday/ PaydayWidget/ --include='*.swift' 2>/dev/null \
      | grep -v "^$STATE:" | sed -E 's#^[^:]*:##; s#//.*##' \
      | grep -cE "PaydaySyncState\.${sym}\b")
  inside=$(sed -E 's#//.*##' "$STATE" | grep -vE "func[[:space:]]+${sym}\b" \
      | grep -cE "(^|[^.[:alnum:]_]|Self\.|PaydaySyncState\.)${sym}[[:space:]]*\(")
  echo $((outside + inside))
}

accessors() {
  grep -nE "^    (static (func|var)|private static)" "$STATE" \
    | grep -v "private static" \
    | sed -E 's/.*static (func|var) ([a-zA-Z_][a-zA-Z0-9_]*).*/\2/' | sort -u
}

# The same reason, one step later: the file is there but its declarations no
# longer have the shape this lint looks for.
if [ -z "$(accessors)" ]; then
  echo "[FAIL] found no accessor in $STATE, so the wiring lint has nothing to check"
  exit 1
fi

allowed_symbols=""
while read -r sym marker _; do
  case "$sym" in ''|'#'*) continue;; esac
  allowed_symbols="$allowed_symbols $sym"
  if ! grep -q "$marker" "$GATE"; then
    echo "[FAIL] allowlist entry '$sym' names marker '$marker', absent from $GATE"
    echo "   -> The condition was resolved or renamed. Wire the symbol, or re-justify the entry."
    FAIL=1
  fi
  n=$(readers "$sym")
  if [ "$n" -gt 0 ]; then
    echo "[FAIL] allowlist entry '$sym' now has $n production reader(s)"
    echo "   -> It is wired. Remove it from $LIST."
    FAIL=1
  fi
done < "$LIST"

while read -r sym; do
  [ -z "$sym" ] && continue
  n=$(readers "$sym")
  if [ "$n" -eq 0 ]; then
    case " $allowed_symbols " in
      *" $sym "*) ;;
      *) echo "[FAIL] $STATE exposes '$sym' and nothing in Payday/ or PaydayWidget/ reads it"
         echo "   -> Wire it, delete it, or add it to $LIST with a marker that exists in $GATE."
         FAIL=1;;
    esac
  fi
done < <(accessors)

[ "$FAIL" = "1" ] && { echo "=== PaydaySyncState wiring lint FAILED ==="; exit 1; }
echo "[PASS] every PaydaySyncState accessor is read, or allowlisted against a live blocking condition"
