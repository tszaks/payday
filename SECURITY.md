# Security policy

## Supported versions

Only the latest release of Payday on the App Store gets security fixes.

| Version | Supported |
|---|---|
| Latest App Store release | Yes |
| Older | No |

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

Use GitHub private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. If that is not available to you, email tyler@szakacsmedia.com.

Please include:

- What you found and what an attacker could do with it.
- Steps to reproduce.
- Your iOS version and Payday version (Settings > About in the app, or the App Store listing).

You can expect a first reply within a few days. Payday is maintained by a small team, so a fix may take longer, but you will get updates.

## What counts

Payday stores shift, tip and pay data for signed-in users. These areas matter most:

- Anything that lets one user read or change another user's data (row-level security, the `payday-api` edge function, API keys and MCP access).
- Sign in with Apple and session handling.
- Anything that leaks data to a third party that the documentation does not name.
- Secrets committed to the repository.

The source is public for reference. It is not licensed for reuse; see the license note in the [README](README.md#license).
