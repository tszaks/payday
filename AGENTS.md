# Payday

An iOS 26 tip and shift tracker. SwiftUI app, widgets, a single Swift earnings engine (`PaydayCore`), and a Supabase backend. The source is public for reference and all rights are reserved: it is not licensed for reuse.

This file is for AI agents that work **on** Payday's code. For the agent-facing REST and MCP API, read [docs/PAYDAY_API.md](docs/PAYDAY_API.md). Start at [docs/README.md](docs/README.md) for product and design intent.

## Build and test
- The Xcode project comes from `project.yml`. It is git-ignored. Run `xcodegen generate` after adding, removing or renaming files.
- Debug builds read the git-ignored `Secrets.local.xcconfig`. An empty key works: `echo 'OPENAI_API_KEY =' > Secrets.local.xcconfig`. Never commit a real key.
- Earnings engine (no simulator): `swift test --package-path Packages/PaydayCore`
- App and widget: `xcodebuild test -project Payday.xcodeproj -scheme Payday -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- Edge function: `cd supabase/functions/payday-api && deno test`
- Design lint: `bash scripts/design-lint.sh`
- Migrations: `supabase start && supabase db reset --local` (needs Docker). See [docs/CI.md](docs/CI.md) for the SQL test runners.
- Run every suite that reads the code you changed. CI runs five required jobs on `production`; all must be green.

## Code map
- `Payday/`: SwiftUI app. `Views/`, `Sync/`, `Intents/` (App Intents), `Earnings/`, `Models/`, `Diagnostics/`, `Design/`.
- `PaydayWidget/`: widgets, controls, the shift Live Activity.
- `Packages/PaydayCore/`: the earnings engine (`Ledger`, `Paycheck`, `Policy`, `Query`, `Snapshot`, `Values`, `Copy`, `Input`).
- `PaydayTests/`: app and widget tests.
- `supabase/`: `migrations/`, `tests/`, `functions/payday-api/`.
- `scripts/`: archive, CI helpers, database test runners and lints.
- `docs/`: product, design, engineering and release documents.

## Conventions
- Match the surrounding code: naming, comment density, idiom.
- **One engine.** Every number the app shows, speaks, exports or serves comes from `PaydayCore`. Do not compute a figure in a view, a widget or the edge function. See [docs/METRICS.md](docs/METRICS.md).
- Follow [docs/DESIGN.md](docs/DESIGN.md). `scripts/design-lint.sh` enforces part of it.
- Migrations are append-only. Add a new file in `supabase/migrations/`; never edit an applied one.
- Work lands through pull requests into `production` (the default branch) with CI green.

## Do not
- Do not add a `LICENSE`, `CONTRIBUTING.md` or `CODE_OF_CONDUCT.md`. The repository is deliberately all rights reserved.
- Do not commit secrets, API keys, user data or `Secrets.local.xcconfig`. `Secrets.release.xcconfig` is committed on purpose and must stay empty of secrets.
- Do not bump the version or build number unless asked. Do not run archive or upload scripts unless asked.
- Do not weaken or delete a test or a CI job to make a change pass.
