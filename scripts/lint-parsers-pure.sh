#!/usr/bin/env bash
# Parsers produce CANDIDATES. They never persist.
#
# The last unenforced item on PR 7's list. The property is true today --
# none of the five parser files mentions `.insert(`, `.save()` or
# `ModelContext` -- and nothing was holding it there.
#
# WHY IT MATTERS, rather than as tidiness: a parser's output is a GUESS. It
# comes from OCR or from a model, and the whole design is that a person
# confirms it before it becomes money. A parser that writes has removed the
# confirmation step without anyone deciding to, and the failure is silent --
# the shift simply appears, already wrong, attributed to the user.
#
# It is also the easiest rule in the codebase to break by accident, because
# "just save it here" is one line and reads as a convenience.
#
# Scope: the five files under Payday/Utilities that parse or cache scan
# results. A new parser must be added to this list -- which is deliberate,
# since deciding a file is a parser is a design judgement a lint cannot make.
set -uo pipefail

PARSERS=(
  Payday/Utilities/PaycheckAIParser.swift
  Payday/Utilities/ReceiptAIParser.swift
  Payday/Utilities/ScanImageEncoder.swift
  Payday/Utilities/ScanResultCache.swift
  Payday/Utilities/ShiftReceiptMetrics.swift
)
BANNED='\.insert\(|\.save\(\)|ModelContext|modelContext'
FAIL=0

for f in "${PARSERS[@]}"; do
  [ -f "$f" ] || { echo "[FAIL] $f is listed as a parser but does not exist"; FAIL=1; continue; }
  hits=$(grep -nE "$BANNED" "$f" || true)
  if [ -n "$hits" ]; then
    echo "[FAIL] $f persists; parsers must return candidates only"
    echo "$hits" | sed 's/^/   /'
    echo "   -> Return the parsed value and let ShiftCommands persist it after the user confirms."
    FAIL=1
  fi
done

[ "$FAIL" = "1" ] && { echo "=== Parser purity lint FAILED ==="; exit 1; }
echo "[PASS] all ${#PARSERS[@]} parsers return candidates and persist nothing"
