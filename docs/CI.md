# CI

`.github/workflows/ci.yml` runs on every pull request and on every push to
`production`. Superseded runs on the same ref are cancelled automatically
(`concurrency`). Five jobs, all independent:

## core-tests — PaydayCore (`swift test`)

Runs `swift test --package-path Packages/PaydayCore` on `macos-latest`. No
simulator, no Xcode project. This is the fast, cheap check for anything
living in `Packages/PaydayCore`.

Run locally:

```sh
swift test --package-path Packages/PaydayCore
```

### Known-issue release gate (`KnownIssuesGateTests`)

`Packages/PaydayCore/Tests/PaydayCoreTests/Fixtures/KnownIssues.json` is a
JSON array of fixture IDs whose tests cannot pass yet. A fixture test for a
listed ID wraps its assertions in `withKnownIssue("<id> pending: see
docs/METRICS.md")` (via the `expectingKnownIssues(for:)` helper in
`Tests/PaydayCoreTests/Support/KnownIssues.swift`), so CI stays green while
the failure stays visible in the log as a known issue rather than disappearing.

`KnownIssuesGateTests.knownIssueCountIsZero` (tagged `.releaseGate`) asserts
that list is empty. The plan called for excluding it from the per-PR run with a
tag filter, but `swift test --skip` matches test *names*, not tags, and there
is no tag-based skip in `swift test`. So the same test runs in both jobs and
the environment decides how strict it is:

- `PAYDAYCORE_RELEASE_GATE=1` (set by hand; no workflow in `.github/workflows` sets it): the test
  asserts `KnownIssues.all.isEmpty` and FAILS the run if any fixture is still
  listed. Message: `Release blocked: known issues pending [...]`.
- Not set (the per-PR `core-tests` job): the test passes. When the list is
  non-empty the passing expectation's message names the pending IDs
  (`Release gate not armed ...; N known issue(s) pending: W1, W2`), so they
  are visible in a verbose log without being recorded as an issue.

The list must shrink as fixtures go green, and that is enforced in the
ordinary per-PR run, not only at release. `withKnownIssue` (without
`isIntermittent: true`) records a `knownIssueNotRecorded` issue and FAILS the
run when its body passes, so listing an ID whose fixture test already passes
is itself a red build. Two things make that bite for every listed ID:

- `FixtureConsistencyTests.everyFixtureConverts` is parameterized over every
  fixture in the bundle (one case per ID) and wraps each case in
  `expectingKnownIssues(for: id)`, so every fixture ID is claimed by at least
  one wrapped test.
- `KnownIssuesGateTests.everyKnownIssueIsClaimedByAWrappedTest` fails when a
  listed ID is not a fixture in the bundle, which is the only way an ID could
  escape that wrapper. It is order-independent: it asserts membership, not
  that some other test already ran.

Remove the ID from `KnownIssues.json` in the same PR that makes its fixture
pass; never leave a green fixture on the list.

With `[]` both the unarmed and the armed
run pass. With `["W1","W2"]` (both fixtures green) the UNARMED run
fails with two `Known issue was not recorded` issues against
`everyFixtureConverts`, and the armed run also fails with
`Release blocked: known issues pending ["W1", "W2"]`. With `["NOPE"]` the
unarmed run fails on the claimed-by-a-wrapped-test check.

Run the gate by hand:

```sh
PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore --filter KnownIssuesGateTests
```

## ios-tests — Payday app + widget (`xcodebuild test`)

Runs on `macos-latest`. Installs `xcodegen`, regenerates `Payday.xcodeproj`
from `project.yml` (both are gitignored and never committed), then picks the
first available iPhone simulator at runtime from `xcrun simctl list devices
available -j` — CI runner images change their pre-installed simulators over
time, so the workflow never hardcodes a UDID. `CODE_SIGNING_ALLOWED=NO`
because CI has no signing identity.

Run locally (swap in a UDID from your own Mac):

```sh
xcrun simctl list devices available -j   # find a UDID
xcodegen generate
xcodebuild test \
  -scheme Payday \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath /tmp/payday-dd
```

Add `CODE_SIGNING_ALLOWED=NO` to the `xcodebuild` line to match CI's unsigned
environment; leave it off for a signed local build.

## edge-tests — payday-api and payroll-connect (`deno test`)

Runs on `ubuntu-latest` via `denoland/setup-deno@v2`. Runs `deno test` for
the Supabase edge function at `supabase/functions/payday-api`, then a second
step, `deno test (payroll-connect)`, for `supabase/functions/payroll-connect`.

Run locally:

```sh
cd supabase/functions/payday-api
deno test
cd ../payroll-connect
deno test
```

## design-lint — `scripts/design-lint.sh`

Runs on `ubuntu-latest`. Zero-tolerance grep lint over `Payday` and
`PaydayWidget` for the Vero-sister-app design contract (`docs/DESIGN.md`). It
also scans `supabase/**/*.sql` and `project.yml` for its non-UI checks.

Run locally:

```sh
bash scripts/design-lint.sh
```

## db-migrations — Supabase migrations and SQL tests (`supabase db reset`)

Runs on `ubuntu-latest` via `supabase/setup-cli@v1`, with the Supabase CLI
pinned to `version: 2.117.0` (never `latest`: a floating CLI can change what
`db reset` does with no change in this repo, and resolving `latest` hits the
GitHub releases API rate limit). Steps, in order:

1. `supabase start`: starts a local Supabase stack.
2. `supabase db reset --local`: applies every migration in
   `supabase/migrations` from scratch, proving the migration history is
   consistent and replayable end to end.
3. SQL schema tests: runs every `supabase/tests/*_test.sql` file with
   `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f <file>`.
   Each script records its assertions in a temporary table and raises at the
   end if any failed, so a failure is a non-zero exit.
4. SQL concurrency tests: `bash scripts/db-test-race.sh
   "postgresql://postgres:postgres@127.0.0.1:54322/postgres"`. These facts
   need two or three concurrent sessions, which one psql script cannot
   produce, so the script drives real psql processes against the same stack.
5. `supabase stop`.

Run locally (requires Docker):

```sh
supabase start
supabase db reset --local
for f in supabase/tests/*_test.sql; do
  psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f "$f"
done
bash scripts/db-test-race.sh "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
supabase stop
```

Run locally without Docker (needs Homebrew `postgresql@17`): `bash
scripts/db-test-local.sh` applies the migrations to a throwaway cluster in
`/tmp` and runs the `supabase/tests` suites. It does not run the concurrency
suite; run `bash scripts/db-test-race.sh` (no argument) for that.

## Why the iOS job writes `Secrets.local.xcconfig`

`project.yml` points the Debug configuration at `Secrets.local.xcconfig`, which is gitignored because it carries a local-only OpenAI key for Insights narration. On a clean checkout xcodegen fails with `Invalid config file "Secrets.local.xcconfig"`. The iOS job therefore writes a placeholder whose only line is `OPENAI_API_KEY =` before generating the project. That matches the committed Release config, so `InsightsService.isConfigured` is false on CI and the tests run the deterministic fallback path, never a live model call.

## Wall-clock performance budgets are scaled on CI

`PaydayTests/RenderFactsPerformanceTests.swift` holds six wall-clock tests. Every budget is 0.85s except Insights, which is 1.0s. They measure the machine as much as the code: a developer Mac passes comfortably, but GitHub's shared macOS runners are 20-40% slower and vary between runs.

`RenderFactsPerformanceTests.budgetScale` is therefore `4` when the `CI` environment variable reaches the test process and `1` otherwise. The tests run in the host app on the simulator, which does not inherit the runner's environment, so the workflow sets `TEST_RUNNER_CI=true` on the `xcodebuild test` step: `xcodebuild` forwards a shell variable named `TEST_RUNNER_<VAR>` into the test process as `<VAR>`. A plain `CI=true` does not reach the tests and leaves the scale at `1`. A genuine algorithmic regression is an order of magnitude, not 20%, so the guard still fires on CI; runner variance does not. Every failure message prints the measured seconds, the raw budget, and the scale in force.

Run them with the CI budget locally: `TEST_RUNNER_CI=true xcodebuild test -scheme Payday -only-testing:PaydayTests/RenderFactsPerformanceTests ...`.
