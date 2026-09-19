#!/usr/bin/env bash
# Every backticked camelCase identifier in a gate document must name
# something that exists in the codebase.
#
# Written because RELEASE_GATE.md cited a test called
# "anEditThatThrowsLeavesTheRecordExactlyAsItWas". No such symbol exists. It
# was the test's DISPLAY string --
# @Test("an edit that throws leaves the record exactly as it was") --
# camel-cased by hand into something shaped like an identifier and written
# into the gate as if it were one. The test is real; the name was not. A
# reviewer grepped it, found nothing, and reasonably concluded the coverage
# was phantom.
#
# That is worse than a typo. A gate document citing names that resolve to
# nothing is a rubber stamp shaped like evidence, and it fails in the
# direction that LOOKS like rigour.
#
# Scope note: this checks that the name EXISTS, not that it proves what the
# row claims. A lint cannot read an argument. It closes the specific hole
# where a citation cannot be followed at all.
set -uo pipefail

DOCS=("docs/RELEASE_GATE.md")
ROOTS=(Payday PaydayTests Packages scripts supabase docs)
FAIL=0

for doc in "${DOCS[@]}"; do
  [ -f "$doc" ] || continue
  while read -r id; do
    [ -z "$id" ] && continue
    # Search everywhere EXCEPT the doc itself, or a name would vouch for
    # its own mention.
    if ! grep -rl --exclude="$(basename "$doc")" "$id" "${ROOTS[@]}" >/dev/null 2>&1; then
      echo "[FAIL] $doc cites '$id', which exists nowhere in the codebase"
      echo "   -> Cite the SYMBOL (function name), not a camel-cased test display string."
      echo "      Swift Testing prints @Test(\"...\") display names; the function is named separately."
      FAIL=1
    fi
  done < <(grep -oE '`[a-z][a-zA-Z0-9_]{12,}`' "$doc" | tr -d '`' | sort -u)
done

if [ "$FAIL" = "1" ]; then
  echo "=== Doc citation lint FAILED ==="
  exit 1
fi
echo "[PASS] every backticked identifier in the gate docs names something real"
