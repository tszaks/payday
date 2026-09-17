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
