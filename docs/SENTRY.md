# Crash reporting

Payday reports crashes to Sentry, in the organization `szakacs-media`.

## Status: wired, inert, waiting on one thing

Everything on the app side is built and tested. Nothing is being collected,
because there is no DSN yet.

`PaydayCrashReporting.start()` reads `SENTRY_DSN` from the bundle and returns
immediately when it is missing or blank. No SDK starts, no network, no disk.
That is also how Debug builds, unit tests and CI stay silent: not a build flag,
just the absence of a value. `PaydayCrashReportingTests` asserts it.

## What Tyler has to do (three steps)

I could not do any of these. Creating the project returned
`403 Your organization has disabled this feature for members`, and the local
`sentry-cli` token is `401 Invalid token` — the same dead token noted for the
Vero work.

**1. Create the project.** In Sentry, organization `szakacs-media`, team
`szakacs-media-company`. Name it `Payday`, slug `payday`, platform
`apple-ios`. That provisions the DSN automatically.

**2. Paste the DSN into `project.yml`.** One line, already present and blank:

```yaml
SENTRY_DSN: ""
```

A Sentry DSN is a **write-only ingest key** and is designed to be embedded in a
shipped client — it can send events and read nothing. So it belongs in
`project.yml` next to `SUPABASE_PUBLISHABLE_KEY`, not in the gitignored
`Secrets.local.xcconfig` where the OpenAI key lives. The OpenAI key is a real
secret and is deliberately absent from release builds; this is not, and
committing it is the normal practice.

**3. Create an auth token for dSYM upload**, or crashes arrive as raw
addresses and are unreadable. Sentry → Settings → Auth Tokens, scope
`project:releases`. Then either export it locally before running the upload
below, or add it as the GitHub secret `SENTRY_AUTH_TOKEN`.

## Symbolication

Payday is archived by hand from `production`, so the upload is a step in that
process rather than a build phase. A build phase would need the token present
on every machine that compiles the app, and would fail the build for anyone
without it.

After archiving, with `SENTRY_AUTH_TOKEN` exported:

```sh
sentry-cli --org szakacs-media --project payday \
  upload-dif --include-sources \
  ~/Library/Developer/Xcode/Archives/<date>/Payday\ <time>.xcarchive/dSYMs
```

The release name the app reports is `payday@<MARKETING_VERSION>+<CURRENT_PROJECT_VERSION>`,
for example `payday@1.0+9142029`. Sentry matches a dSYM by build UUID rather
than by that string, so the name only has to be consistent, but it is the
string you will search for in the UI.

## What is deliberately NOT collected

Crash reporting in an earnings app is not the same problem as crash reporting
in a game. Every screen in Payday is somebody's income, and the defaults of an
iOS crash reporter capture a lot of what was on screen. The rule is that a
report describes the **fault** and never the **figures**.

`PaydayCrashScrubber` is a separate type from the reporter, operating on plain
Sentry model objects, precisely so that every rule below is asserted by a test
that needs no DSN, no network and no running SDK. An untested privacy rule is a
hope rather than a rule.

| Refused | Why it matters here specifically |
|---|---|
| Screenshots | A screenshot of Payday is a picture of somebody's wages, and unlike a string it cannot be redacted afterwards. |
| View hierarchy | It carries accessibility labels, and in this app a label is very often a formatted amount, because that is what the button says. |
| UI and touch breadcrumbs | Dropped outright, not redacted. The value of a tap breadcrumb IS the name of the element touched, and the element is called `$247.50`. |
| User identity | `event.user` is cleared on every event. Payday signs in with Apple, so the identifier available to the SDK is the one thing that would turn a crash report into a named person's finances. Nothing calls `SentrySDK.setUser`; this holds even if something later does. |
| Device name | Usually the owner's name. `event.serverName` is cleared. |
| Query strings | A Supabase read is `/rest/v1/shifts?user_id=eq.<uuid>&select=...`. The path survives, so you still know which table failed; the query does not. |
| Request and response bodies | Removed rather than redacted. A body here is rows of somebody's wages, and it is never diagnostic enough to justify that. |
| Performance traces | `tracesSampleRate` is 0. There is no latency question worth answering with traces, and a transaction name is another place a screen's contents can leak. |

On top of those, any text that still reaches an event passes a money regex,
which redacts anything with a currency symbol in front of it.

**Its limit, stated rather than hidden:** a bare integer of cents is not
caught. `fatalError("tips 24750 out of range")` would ship that number. The
convention that covers the gap is that no error message in this app formats
money into its text, and `bareCentsAreNotCaught` records the gap as a test so
it stays a known one. Bare numbers are not redacted on purpose — the counts,
indexes and status codes in a message are what make a crash diagnosable.

## Not yet covered

The widget and the App Intents extension crash in their own processes and are
**not** reporting. Each would need its own DSN plumbing and its own
screenshot / view-hierarchy suppression, since both render money. Worth doing;
kept out of the change that establishes the rules above.
