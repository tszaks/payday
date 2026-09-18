#!/usr/bin/env bash
# Wait for a PR's checks to reach a terminal state, and FAIL CLOSED.
#
# Written because the ad-hoc version of this merged PR #65 before CI ran.
# That loop was `if ! gh pr checks N | grep -q pending; then break`, and
# `gh pr checks` returns "no checks reported on the 'X' branch" during the
# window before checks attach to a fresh PR. No "pending" in that string, so
# the loop exited and reported a terminal state while CI was still running.
#
# THE BUG WAS TWO STATES WHERE THERE ARE THREE. "not yet observable",
# "observed and incomplete", and "observed and complete" are different facts,
# and collapsing the first into the third is what merged it. Same invalid
# step as "grep found nothing, therefore untested": an empty observation is
# not a positive fact.
#
# Usage:
#   scripts/wait-for-ci.sh <pr-number> [expected-head-sha]   # a pull request
#   scripts/wait-for-ci.sh --commit <sha>                    # any commit
#
# The --commit mode exists because the thing that actually ships is the MERGE
# COMMIT, not the PR head, and a PR-only watcher cannot see it. Two sessions
# independently needed it on 2026-09-18 and both fell back to reading the API
# by hand -- which is how a conclusion gets missed: the peer's watcher logged
# one merge commit twice and never logged the other's verdict at all.
#
# Exit 0 = every check concluded SUCCESS (or NEUTRAL/SKIPPED).
# Exit 1 = at least one check concluded in a failure class.
# Exit 2 = timed out still incomplete, or the head SHA moved.
set -uo pipefail

MODE=pr
if [[ "${1:-}" == "--commit" ]]; then MODE=commit; shift; fi
PR="${1:?usage: wait-for-ci.sh <pr-number> [sha] | --commit <sha>}"
EXPECTED_SHA="${2:-}"
INTERVAL="${CI_WAIT_INTERVAL:-30}"
MAX_TICKS="${CI_WAIT_TICKS:-80}"

for ((tick = 1; tick <= MAX_TICKS; tick++)); do
  if [[ "$MODE" == commit ]]; then
    # Normalised into the same shape as a PR rollup so ONE set of predicates
    # judges both. Two copies of "is this terminal?" is two chances to get it
    # wrong, and getting it wrong is the entire subject of this script.
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
    json=$(gh api "repos/$repo/commits/$PR/check-runs" 2>/dev/null \
      | jq --arg sha "$PR" '{headRefOid: $sha, statusCheckRollup:
          [.check_runs[]? | {name, status: (.status|ascii_upcase),
                             conclusion: (.conclusion // "" |ascii_upcase)}]}') || json=""
  else
    json=$(gh pr view "$PR" --json headRefOid,statusCheckRollup 2>/dev/null) || json=""
  fi

  if [[ -z "$json" ]]; then
    echo "tick $tick: target not readable (NOT treated as done)"
    sleep "$INTERVAL"; continue
  fi

  sha=$(jq -r '.headRefOid // ""' <<<"$json")
  # A moved head means the thing that went green is not the thing you
  # reviewed. Refuse rather than report on the wrong object.
  if [[ -n "$EXPECTED_SHA" && "$sha" != "$EXPECTED_SHA"* ]]; then
    echo "REFUSING: head moved to ${sha:0:7}, expected ${EXPECTED_SHA:0:7}"
    exit 2
  fi

  total=$(jq '[.statusCheckRollup[]?] | length' <<<"$json")
  # An EMPTY rollup is "not yet observable", never "complete". This is the
  # exact state the broken watcher misread.
  if [[ "$total" -eq 0 ]]; then
    echo "tick $tick: no checks attached yet (NOT treated as done)"
    sleep "$INTERVAL"; continue
  fi

  # Only an explicit COMPLETED status counts as observed-and-complete.
  incomplete=$(jq '[.statusCheckRollup[]?
    | select((.status // "COMPLETED") != "COMPLETED")] | length' <<<"$json")
  failed=$(jq -r '[.statusCheckRollup[]?
    | select(.conclusion // "" | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"))
    | .name] | join(", ")' <<<"$json")

  if [[ -n "$failed" ]]; then
    echo "FAILED at ${sha:0:7}: $failed"
    exit 1
  fi
  if [[ "$incomplete" -eq 0 ]]; then
    echo "GREEN at ${sha:0:7}: $total checks, 0 failing, 0 incomplete"
    exit 0
  fi

  echo "tick $tick: $incomplete of $total still running"
  sleep "$INTERVAL"
done

echo "TIMED OUT still incomplete after $((MAX_TICKS * INTERVAL))s"
exit 2
