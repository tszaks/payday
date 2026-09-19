#!/usr/bin/env bash
# Merge a PR only if it is green RIGHT NOW. Refuse otherwise.
#
# Written because the three-step sequence I had been running by hand -- read
# the verdict line, confirm with a second instrument, check the tip -- decayed
# into theatre and merged PR #80 with three of five checks still running.
#
# The transcript of that merge is the whole argument for this script:
#
#   1. verdict: GREEN at 81bc159 (from watcher)    <- a hardcoded echo
#   2. second instrument: PR80 OPEN: ,,SUCCESS,SUCCESS,   <- 2 of 5, the truth
#   3. tip: match=YES
#   [merged]
#
# Step 1 was a literal string. It measured nothing and could not fail. Step 2
# printed the real state and nothing was conditioned on it -- the merge was
# gated on the tip comparison alone. A procedure whose steps are printed but
# not ENFORCED is the artifact-that-checks-nothing shape, built into my own
# merge habit.
#
# The trigger was subtle and worth recording: the checks had genuinely been
# green, and then I cancelled and re-ran a wedged workflow, which RE-ARMED
# them. My own recovery action invalidated the verdict I was still relying
# on. A verdict is a reading of a moment, not a property of a commit.
#
# Usage: scripts/merge-if-green.sh <pr-number>
# Exit 0 merged. 1 refused (not green / tip moved). 2 could not determine.
set -uo pipefail

PR="${1:?usage: merge-if-green.sh <pr-number>}"
ERRFILE="$(mktemp)"; trap 'rm -f "$ERRFILE"' EXIT

json=$(gh pr view "$PR" --json state,headRefName,headRefOid,statusCheckRollup 2>"$ERRFILE")
if [[ -z "$json" ]]; then
  echo "REFUSE: cannot read PR $PR"; [[ -s "$ERRFILE" ]] && sed 's/^/  gh: /' "$ERRFILE"; exit 2
fi

state=$(jq -r '.state' <<<"$json")
[[ "$state" == "OPEN" ]] || { echo "REFUSE: PR $PR is $state"; exit 1; }

sha=$(jq -r '.headRefOid' <<<"$json")
branch=$(jq -r '.headRefName' <<<"$json")
total=$(jq '[.statusCheckRollup[]?] | length' <<<"$json")
incomplete=$(jq '[.statusCheckRollup[]? | select((.status // "COMPLETED") != "COMPLETED")] | length' <<<"$json")
failing=$(jq -r '[.statusCheckRollup[]?
  | select(.conclusion // "" | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"))
  | .name] | join(", ")' <<<"$json")

# An empty rollup is "not yet observable", never "nothing failed".
[[ "$total" -eq 0 ]] && { echo "REFUSE: no checks attached to ${sha:0:7} yet"; exit 1; }
[[ -n "$failing" ]]  && { echo "REFUSE: failing at ${sha:0:7}: $failing"; exit 1; }
[[ "$incomplete" -gt 0 ]] && {
  echo "REFUSE: $incomplete of $total still running at ${sha:0:7}"; exit 1; }

# The reviewed commit must still be the tip, or the green belongs to
# something else.
# `timeout` because an unbounded fetch HANGS the caller. A polling loop
# around this script wrote one line in 38 minutes and then nothing: the
# loop was alive, stuck inside a fetch that never returned, and from
# outside it looked exactly like "CI is still running". A monitor that can
# hang reports a false state, which is the one thing a monitor must not do.
timeout 60 git fetch -q origin "$branch" 2>"$ERRFILE" || true
remote=$(git rev-parse "origin/$branch" 2>/dev/null || echo "")
[[ "$remote" == "$sha" ]] || {
  echo "REFUSE: tip is ${remote:0:7}, PR head is ${sha:0:7}"; exit 1; }

echo "GREEN at ${sha:0:7}: $total checks, 0 failing, 0 incomplete -- merging"
gh pr merge "$PR" --squash
