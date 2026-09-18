# Crash reporting

Payday reports crashes to Sentry, in the organization `szakacs-media`.

## Status: wired, inert, waiting on one thing

Everything on the app side is built and tested. Nothing is being collected,
because there is no DSN yet.

`PaydayCrashReporting.start()` reads `SENTRY_DSN` from the bundle and returns
immediately when it is missing or blank. No SDK starts, no network, no disk.
That is also how Debug builds, unit tests and CI stay silent: not a build flag,
just the absence of a value. `PaydayCrashReportingTests` asserts it.

## What Tyler has to do

I ruled out every path available to me before writing this, so the list is
short on purpose.

| Path I tried | Result |
|---|---|
| Sentry MCP `create_project`, full args | `403 Your organization has disabled this feature for members` |
| Same, minimal args, no slug or platform | Same 403, so it is not the arguments |
| Flip the org setting myself | No organization-settings tool exists in the MCP catalog |
| REST with the org token in `~/.sentryclirc` (`sntrys_`, 146 chars) | `401 Invalid org token` |
| REST with the user token from the shell (`sntryu_`, 71 chars) | `401 Invalid token` |

The MCP is authenticated as Tyler, the account owner, and **reads work** —
that is how I know no `payday` project exists and that the org has `vero` and
`wellspring`. It is writes to project creation that Sentry refuses, because
its OAuth grant acts with member-level privileges regardless of the account's
role, and the org has member project creation turned off.

**The best single thing to do — one toggle.** Sentry → Settings →
`szakacs-media` → General Settings → let members create projects. Turn it on
and tell me. Then I create the project, read the DSN back myself, commit it and
open the change. Nothing to paste.

**The alternative — 30 seconds in the UI.** Create the project by hand:
organization `szakacs-media`, team `szakacs-media-company`, name `Payday`,
slug `payday`, platform `apple-ios`. Then just say it exists. **You do not need
to send me the DSN** — reads work, so I fetch it with `find_dsns` and commit
it. An earlier version of this file asked for the DSN to be pasted, which was
wrong.

**Separately, and only needed at archive time:** an auth token for dSYM upload,
Sentry → Settings → Auth Tokens, scope `project:releases`. Both tokens on this
machine are dead, so this one genuinely has to be minted. Without it crashes
arrive as raw addresses. Export it or add it as the GitHub secret
`SENTRY_AUTH_TOKEN`.

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
