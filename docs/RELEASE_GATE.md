# PaydayCore release gate

Pass/fail, not a score. No line is satisfied by an argument; each names the command or the act that produces it. Tied to a specific release-candidate commit, not to "the branch".

Two kinds of line. **Machine lines** a session can run and must keep green. **Human lines** that physically need Tyler's phone, his pay period, or a professional's judgement, and that no session may mark done. A goal that reports complete with an open human line is lying.

Status legend: `[ ]` not yet, `[x]` green with evidence recorded below it, `[H]` human line, never checkable here.

---

## Candidate

- Commit: _fill in at candidate time_
- Build number: _MDDYY+seq_
- Date: _fill in_

## Machine lines

### Engine correctness
- [ ] `swift test --package-path Packages/PaydayCore` green. Record the `Test run with N tests in M suites` line.
- [ ] App suite green. Record the **Swift Testing** total, not the `Executed N tests` lines, which count only the two XCTest files and have hidden a real failure before. Must be at or above the then-current baseline.
- [ ] All 14 golden fixtures (W1-W3, N1-N3, M1, H1, P1, E1, S2, Z1, T1, C1) pass **against the real production engine and screen adapters**, not a test helper. The original `CalendarDayTotalTests` passed for years while testing a formula the calendar did not use.
- [ ] `PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore --filter KnownIssuesGate` green, with `Fixtures/KnownIssues.json` empty. A pending known issue blocks the release; it is not a note.

### Parity, on real adapters
- [ ] Dashboard period income == History period row == period detail.
- [ ] Calendar day == day detail == sum of that day's shifts == the chart point for the same metric.
- [ ] Month == sum of its days. Pay period == sum of its eligible ledger entries. YTD clips periods crossing the year boundary rather than summing whole overlapping periods.
- [ ] Siri == widget == in-app current period, for the same `asOf` and source revision.
- [ ] A shift's wages sum across day, month, pay period and year to the same cents, including a workweek that straddles a month boundary.

### Honesty of state
- [ ] A failed read is never rendered as `$0`. Verified by breaking the widget's store access in a debug build and seeing "Couldn't load".
- [ ] `.partial` completeness never renders the word "Total". Verified by removing hours from one shift and reading the headline.
- [ ] Wages estimated from the legacy rate carry their caption until the rate-history prompt is answered.
- [ ] The overtime policy is presented as an estimate everywhere it appears.

### Boundaries
- [ ] Money-boundary lint rules green, and each one proven to fire by planting a violation in a scratch copy.
- [ ] Every superseded calculation path deleted, not wrapped. `grep` for the retired symbols returns nothing outside the engine and its adapters.
- [ ] Package imports Foundation and CryptoKit only.
- [ ] `docs/PRODUCT.md` Pillar 8 describes what the engine actually guarantees, with no claim the tests do not back.

### Data lifecycle
- [ ] Interrupted save, retry replay, offline edit then reconnect, delete then sync, account switch mid-request, midnight rollover, and a device timezone change all pass with no lost, duplicated, or cross-account record.
- [ ] A shift moved across a workweek boundary re-values both weeks.
- [ ] An upgrade from the current TestFlight build's store fixture migrates and verifies.
- [ ] A downgrade purges `ShiftRecord` rows (measured; see `docs/design/S1-downgrade-probe.md`) and the next launch forces a baseline re-pull without ever showing `$0`.
- [ ] Production Supabase migrations applied, each with the affected-table row counts before and after, and each verified first on a scratch local cluster from clean.

### Shadow comparison
- [ ] Every inventory number computed by the pre-PaydayCore path and by the engine over the same store; every difference maps to a named fixture ID. No unexplained cent.

## Human lines — Tyler only

- [H] Clean install on a real device, release configuration, exercised for a full logging session.
- [H] Upgrade in place from the build currently installed from TestFlight, with existing real data, and the totals checked against what they read before.
- [H] A pay-period close observed end to end on the device, including the payday moment.
- [H] A real paycheck reconciled against the engine's expectation, with any discrepancy explained.
- [H] A TestFlight soak across that close with no correctness report from any tester.
- [H] A payroll professional confirms the supported compensation policy is stated correctly for a tipped employee, since 40h/1.5x on the base rate is an estimate and the app says so.

## Rules for whoever fills this in

1. Paste the command and its output. "Verified" alone is not evidence.
2. If a line was not run, write `not run` and why. Do not leave it ambiguous.
3. A red line blocks the release. There is no weighted average and no "mostly green".
4. Re-run every machine line against the final candidate commit. A line green on an earlier commit is not green on this one.
5. Never mark a human line. Not even with Tyler's verbal say-so in chat: the line exists so the act happened.
