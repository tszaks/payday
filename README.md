# Payday

Payday is an iOS tip and shift tracker for hourly and tipped work. Log a shift in under ten seconds, see whether tonight was a good night, and know what your check should say before it lands.

[usepayday.app](https://usepayday.app) · [App Store](https://apps.apple.com/us/app/payday-server-tip-tracker/id6790869268)

## What it does

- **Logs a shift fast.** Cash and credit tips, hours, and the rate you worked at. After you save, one line tells you how the night compared: "$34 above your Friday average."
- **Tracks the pay period.** A pace line shows where you stand against last period and what the period is on track to total.
- **Predicts your paycheck.** Payday already knows your credit tips for the period, so it tells you what the tips line on your stub should read. Enter the real number and it checks the two.
- **Keeps your records.** Best night, best weekday, best period, averages per shift, and your true hourly rate once tips are counted.
- **Lives in the OS.** Home Screen and Lock Screen widgets, a Control Center control, a Live Activity while you are on shift, and Siri and Shortcuts actions for logging tips and asking for your period total.
- **Exports clean records** for taxes or your own bookkeeping.

The stats are computed on the device. Sign in with Apple, and your shifts sync through Supabase so they survive a new phone.

## How the repo is laid out

| Path | What lives there |
| --- | --- |
| `Payday/` | The SwiftUI app: views, sync, App Intents, diagnostics |
| `PaydayWidget/` | Widgets, controls, and the shift Live Activity |
| `Packages/PaydayCore/` | The earnings engine. Every number the app shows, speaks, exports, or serves comes from here, so no two screens can disagree about the same fact |
| `PaydayTests/` | App and widget tests |
| `supabase/` | Database migrations, database tests, and the `payday-api` edge function |
| `scripts/` | Archive, CI helpers, database test runners, and repo lints |
| `docs/` | Product, design, engineering, and release documents. Start at [docs/README.md](docs/README.md) |
| `marketing/` | App Store screenshots and their source |

## Building

Requirements: Xcode 26 or newer, iOS 26 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and is not committed.

```sh
brew install xcodegen

# The Debug config reads a gitignored secrets file. An empty key is fine:
# Insights falls back to its on-device summary.
echo 'OPENAI_API_KEY =' > Secrets.local.xcconfig

xcodegen generate
open Payday.xcodeproj
```

## Testing

```sh
# The earnings engine, no simulator needed
swift test --package-path Packages/PaydayCore

# The app and widget
xcodebuild test -project Payday.xcodeproj -scheme Payday \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

CI runs five independent jobs on every pull request and every push to `production`: PaydayCore tests, app and widget tests, edge function tests, the design lint, and a full Supabase migration reset. [docs/CI.md](docs/CI.md) describes each one and how to run it locally.

## Agent API

Payday exposes the same data through a versioned REST API and a remote MCP endpoint, so AI agents can read and log shifts with their own scoped, revocable keys. See [docs/PAYDAY_API.md](docs/PAYDAY_API.md).

## Branches

`production` is the default branch and what ships. Work lands through pull requests with CI green.

---

Built by [Tyler Szakacs](https://tylerszakacs.com) at [Szakacs Media](https://szakacsmedia.com). Payday is a sister app to [Vero](https://askvero.app).
