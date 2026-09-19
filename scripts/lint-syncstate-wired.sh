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

allowed_symbols=""
while read -r sym marker _; do
  case "$sym" in ''|'#'*) continue;; esac
  allowed_symbols="$allowed_symbols $sym"
  if ! grep -q "$marker" "$GATE"; then
    echo "[FAIL] allowlist entry '$sym' names marker '$marker', absent from $GATE"
    echo "   -> The condition was resolved or renamed. Wire the symbol, or re-justify the entry."
    FAIL=1
  fi
  n=$(grep -rn "\b$sym\b" Payday/ 2>/dev/null \
      | grep -vE "^$STATE:[0-9]+: *(static|private static)" | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    echo "[FAIL] allowlist entry '$sym' now has $n production reader(s)"
    echo "   -> It is wired. Remove it from $LIST."
    FAIL=1
  fi
done < "$LIST"

while read -r sym; do
  [ -z "$sym" ] && continue
  n=$(grep -rn "\b$sym\b" Payday/ 2>/dev/null \
      | grep -vE "^$STATE:[0-9]+: *(static|private static)" | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    case " $allowed_symbols " in
      *" $sym "*) ;;
      *) echo "[FAIL] $STATE exposes '$sym' and nothing in Payday/ reads it"
         echo "   -> Wire it, delete it, or add it to $LIST with a marker that exists in $GATE."
         FAIL=1;;
    esac
  fi
done < <(grep -nE "^    (static (func|var)|private static)" "$STATE" \
         | grep -v "private static" \
         | sed -E 's/.*static (func|var) ([a-zA-Z_][a-zA-Z0-9_]*).*/\2/' | sort -u)

[ "$FAIL" = "1" ] && { echo "=== PaydaySyncState wiring lint FAILED ==="; exit 1; }
echo "[PASS] every PaydaySyncState accessor is read, or allowlisted against a live blocking condition"
