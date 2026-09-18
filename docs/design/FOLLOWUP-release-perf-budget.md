# Follow-up slice: measure the perf tier in Release, not Debug

Authorized by the advisor session under Tyler's delegation of test and CI
decisions, 2026-09-18. Its own slice. **Not blocking S9.**

## Why this exists

S9 raised the `RenderFactsPerformanceTests` 0.5s tier to 0.85s. That raise is
correct and evidenced — see the header of that file for all four
measurements — but it is a **stopgap**, and the advisor's reasoning for why is
the part worth keeping:

> PaydayCore's whole thesis is replacing concrete paths with generic engine
> paths, so every future slice that genericizes a hot loop will slow Debug
> through the same dynamic dispatch and pass Release. A Debug budget will
> drift up slice by slice until it catches nothing.

That is the same lesson as "wall-clock budgets are fragile on shared runners",
one level deeper: the budget is not merely noisy, it is measuring **a build
nobody ships**. At `-Onone` every generic call goes through a witness table;
with optimization the compiler specializes it away. So each slice that moves
a hot loop onto the engine will present as a regression that is not one, and
the honest response each time is to raise the number, which ends with a gate
that cannot fail.

## The change

Move the perf tier to a Release-optimized measurement, so the gate measures
what a user feels rather than what a developer's debug build does.

- A release-configuration test target, or the existing one run with
  `-configuration Release ENABLE_TESTABILITY=YES`. The testability flag is
  required: `@testable import` is unavailable in Release without it, which is
  the only reason the suite sits in Debug today.
- Re-baseline the budgets against the Release figures, which are roughly half
  the Debug ones (measured: production 1.315s, the S9 branch 1.426s, against
  2.095s and 2.659s in Debug).
- Keep the CI scale factor. Shared runners are still slower and still vary;
  that problem is orthogonal and already solved.
- Leave a Debug smoke run if it is cheap, but it must not be the gate.

## What must not happen

Do not delete the budgets. The regression signal they carry is real — an
algorithmic mistake here is an order of magnitude, not 20% — and it is the
only automated guard on a 10,000-row history staying interactive.

Do not raise the Debug tier again to absorb the next slice. If the next
genericization pushes Debug over 0.85s, that is this slice becoming due, not
another number to move.
