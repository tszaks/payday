# CI

`.github/workflows/ci.yml` runs on every pull request and on every push to
`production`. Superseded runs on the same ref are cancelled automatically
(`concurrency`). Five jobs, all independent:

## core-tests — PaydayCore (`swift test`)

Runs `swift test --package-path Packages/PaydayCore` on `macos-latest`. No
simulator, no Xcode project. This is the fast, cheap check for anything
living in `Packages/PaydayCore` (see the module layout in
`~/.claude/plans/option-b-b-full-effervescent-kite.md`, "Module and file
layout").

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

- `PAYDAYCORE_RELEASE_GATE=1` (set by the release workflow, PR 8): the test
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

Verified locally 2026-09-17 (PR 1): with `[]` both the unarmed and the armed
run pass (117 tests). With `["W1","W2"]` (both fixtures green) the UNARMED run
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

Drop `CODE_SIGNING_ALLOWED=NO` locally if you want a signed local build; it's
only needed to match CI's unsigned environment.

## edge-tests — payday-api (`deno test`)

Runs on `ubuntu-latest` via `denoland/setup-deno@v2`. Covers the Supabase
edge function at `supabase/functions/payday-api`.

Run locally:

```sh
cd supabase/functions/payday-api
deno test
```

## design-lint — `scripts/design-lint.sh`

Runs on `ubuntu-latest`. Zero-tolerance grep lint over `Payday` and
`PaydayWidget` for the Vero-sister-app design contract (`docs/DESIGN.md`).

Run locally:

```sh
bash scripts/design-lint.sh
```

## db-migrations — Supabase migrations (`supabase db reset`)

Runs on `ubuntu-latest` via `supabase/setup-cli@v1`. Starts a local Supabase
stack, then applies every migration in `supabase/migrations` from scratch
with `supabase db reset --local`, proving the migration history is
consistent and replayable end to end, then stops the stack.

Run locally (requires Docker):

```sh
supabase start
supabase db reset --local
supabase stop
```

**Unverified in PR 0**: this job could not be exercised in the PR 0
sandbox because local Docker was not available to run `supabase start`.
The workflow YAML was validated with `actionlint` and by hand; the actual
`supabase db reset --local` run against a live local stack is unverified
until it runs in GitHub Actions or on a machine with Docker running.

## Why the iOS job writes `Secrets.local.xcconfig`

`project.yml` points the Debug configuration at `Secrets.local.xcconfig`, which is gitignored because it carries a local-only OpenAI key for Insights narration. On a clean checkout xcodegen fails with `Invalid config file "Secrets.local.xcconfig"`. The iOS job therefore writes a placeholder whose only line is `OPENAI_API_KEY =` before generating the project. That matches the committed Release config, so `InsightsService.isConfigured` is false on CI and the tests run the deterministic fallback path, never a live model call.

## Wall-clock performance budgets are scaled on CI

`PaydayTests/RenderFactsPerformanceTests.swift` holds five wall-clock budgets (four at 0.5s, one at 1.0s). They measure the machine as much as the code: a developer Mac passes comfortably, but GitHub's shared macOS runners are 20-40% slower and vary between runs. On 2026-09-17 the History budget failed at 0.596s against 0.5s on a commit that changed no app code at all.

`RenderFactsPerformanceTests.budgetScale` is therefore `4` when the `CI` environment variable is set (GitHub Actions sets `CI=true`) and `1` locally. A genuine algorithmic regression is an order of magnitude, not 20%, so the guard still fires on CI; runner variance does not. Every failure message prints the measured seconds, the raw budget, and the scale in force.

Run them with the CI budget locally: `CI=true xcodebuild test -scheme Payday -only-testing:PaydayTests/RenderFactsPerformanceTests ...`.
