#!/usr/bin/env bash
# Archive Payday for TestFlight, and REFUSE unless the source is provably current.
#
# Written because build 9191040 shipped from 4d631c9 -- 136 commits behind
# production, with no step-6a call site in the binary. A user opened it,
# synced, and nothing converted. An hour went into ruling out RPC grants and
# migration timing before the answer turned out to be "the archive came from
# the wrong tree".
#
# THE ORDERING IS THE POINT. That build's first archive failed on files
# deleted upstream, which was correctly diagnosed as a stale GENERATED
# project and fixed with `xcodegen generate`. Regenerating made the symptom
# go away and left the cause -- a stale SOURCE tree -- in place. So here the
# freshness check runs FIRST and xcodegen runs only after it passes.
# A guard catches the fact a symptom conceals; a fix for the symptom cannot.
#
# Usage:
#   scripts/archive.sh                 # validate, generate, archive
#   scripts/archive.sh --check-only    # validate and stop (safe to run anywhere)
#   scripts/archive.sh --allow-behind  # archive from a non-current tree, LOUDLY
set -uo pipefail

CHECK_ONLY=0
ALLOW_BEHIND=0
for a in "$@"; do
  case "$a" in
    --check-only)   CHECK_ONLY=1 ;;
    --allow-behind) ALLOW_BEHIND=1 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

FAIL=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; FAIL=1; }

say "=== provenance ==="

# ---------------------------------------------------------------- freshness
git fetch -q origin production || { bad "cannot reach origin"; exit 1; }
HEAD_SHA=$(git rev-parse HEAD)
PROD_SHA=$(git rev-parse origin/production)
BEHIND=$(git rev-list --count HEAD..origin/production)
AHEAD=$(git rev-list --count origin/production..HEAD)

say "  HEAD            ${HEAD_SHA:0:12}"
say "  origin/production ${PROD_SHA:0:12}"
say "  behind=$BEHIND ahead=$AHEAD"

if [ "$BEHIND" -ne 0 ]; then
  if [ "$ALLOW_BEHIND" = 1 ]; then
    say "  !! ARCHIVING FROM A TREE $BEHIND COMMITS BEHIND PRODUCTION, because --allow-behind"
    say "  !! commits this build will NOT contain:"
    git log --oneline HEAD..origin/production | head -20 | sed 's/^/     /'
  else
    bad "HEAD is $BEHIND commits BEHIND origin/production. This is the 9191040 failure."
    say "   -> git merge origin/production   (or pass --allow-behind and read the list)"
  fi
else
  ok "source tree is current with origin/production"
fi

# ------------------------------------------------------------- clean tree
if [ -n "$(git status --porcelain)" ]; then
  bad "working tree is dirty; an archive must come from committed source"
  git status --porcelain | sed 's/^/     /'
else
  ok "working tree clean"
fi

say ""
say "=== versions (project.yml is the ONLY source; the pbxproj is generated) ==="

# ------------------------------------------------------------- versions
# Both targets, four lines. A widget/app CFBundleVersion mismatch is a
# submission rejection, and a one-line bump is exactly the change that gets
# half of it right.
MV=$(grep -E '^ *MARKETING_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/' | sort -u)
CV=$(grep -E '^ *CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/' | sort -u)
MV_N=$(printf '%s\n' "$MV" | grep -c .)
CV_N=$(printf '%s\n' "$CV" | grep -c .)

if [ "$MV_N" -ne 1 ]; then
  bad "MARKETING_VERSION differs between targets: $(echo $MV | tr '\n' ' ')"
else
  ok "MARKETING_VERSION $MV (app and widget agree)"
fi
if [ "$CV_N" -ne 1 ]; then
  bad "CURRENT_PROJECT_VERSION differs between targets: $(echo $CV | tr '\n' ' ')"
else
  ok "CURRENT_PROJECT_VERSION $CV (app and widget agree)"
fi

# A bump written into the generated project is discarded on the next
# regeneration. That is how the first attempt at the 1.0.1 bump was lost.
if [ -d Payday.xcodeproj ] && grep -q "MARKETING_VERSION = $MV" Payday.xcodeproj/project.pbxproj 2>/dev/null; then
  : # consistent, fine
elif [ -d Payday.xcodeproj ]; then
  say "  note: generated project disagrees with project.yml; xcodegen below will fix it"
fi

say ""
say "=== secrets ==="

# Release must not carry the Debug key. `Secrets.local.xcconfig` holds a live
# OpenAI key on this machine and is gitignored; Release points at the tracked
# empty file. Verified rather than assumed, because "it should be fine" is
# how a key ships.
REL_CFG=$(awk '/^ *Release:/ {print $2; exit}' project.yml)
if [ "$REL_CFG" != "Secrets.release.xcconfig" ]; then
  bad "Release configFile is '$REL_CFG', expected Secrets.release.xcconfig"
else
  # `grep -c` prints 0 AND exits 1 when there is no match, so a `|| echo 0`
  # here appends a SECOND zero and the comparison below sees "0\n0" -- a
  # guard that reports a key leak on a clean file. Caught on this script's
  # first run. A gate's false positives are as disqualifying as its misses.
  n=$(grep -cE 'sk-[A-Za-z0-9-]{10,}' "$REL_CFG" 2>/dev/null)
  n=${n:-0}
  if [ "$n" != "0" ]; then bad "$REL_CFG contains $n key-shaped string(s)"; else ok "$REL_CFG carries no key-shaped strings"; fi
fi

if [ "$FAIL" = 1 ]; then
  say ""
  say "=== REFUSED. Nothing was generated and nothing was archived. ==="
  exit 1
fi

say ""
ok "all provenance checks passed"

if [ "$CHECK_ONLY" = 1 ]; then
  say "=== --check-only: stopping before xcodegen ==="
  exit 0
fi

# --------------------------------------------------------------- generate
# AFTER the checks. Never as the remedy for a stale tree.
say ""
say "=== xcodegen (after the checks, never as the fix for a stale tree) ==="
xcodegen generate >/dev/null || { bad "xcodegen failed"; exit 1; }
ok "project regenerated from project.yml"

# ---------------------------------------------------------------- archive
STAMP="$MV+$CV.${HEAD_SHA:0:12}"
OUT="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/Payday $STAMP.xcarchive"
say ""
say "=== archiving Release ==="
say "  -> $OUT"

xcodebuild archive \
  -scheme Payday \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT" \
  2>&1 | tail -5

if [ ! -d "$OUT" ]; then
  bad "no archive produced at $OUT"
  exit 1
fi

# ------------------------------------------------------------ SHA stamping
# A binary on a phone that cannot be traced to a commit is how an hour goes
# into debugging code that was never in it.
plutil -replace PaydaySourceCommit -string "$HEAD_SHA" \
  "$OUT/Products/Applications/Payday.app/Info.plist" 2>/dev/null \
  && ok "stamped PaydaySourceCommit=${HEAD_SHA:0:12} into the app Info.plist" \
  || say "  note: could not stamp Info.plist (archive still valid)"
printf '%s\n' "$HEAD_SHA" > "$OUT/SOURCE_COMMIT"
ok "wrote $OUT/SOURCE_COMMIT"

say ""
say "=== archived $STAMP ==="
say "Next, by hand (needs App Store Connect auth this script deliberately does not hold):"
say "  open the Organizer, Distribute App -> App Store Connect -> Upload"
say "Then the dSYMs, or crashes from this build arrive unsymbolicated:"
say "  sentry-cli upload-dif --include-sources \"$OUT/dSYMs\""
