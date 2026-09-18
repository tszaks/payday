import Foundation
import Sentry

/// What Payday is allowed to send to Sentry, in one place.
///
/// Crash reporting in an earnings app is not the same problem as crash
/// reporting in a game. Every screen in Payday is the user's income, and the
/// default behaviour of an iOS crash reporter is to capture a great deal of
/// what was on screen:
///
/// - A **screenshot** of Payday is a picture of somebody's wages.
/// - A **view hierarchy** carries accessibility labels, and in this app an
///   accessibility label is very often a formatted amount, because that is
///   what the button says.
/// - A **UI breadcrumb** is worse than it looks for the same reason: Sentry
///   names the tapped element, and the element is called `$247.50`.
/// - An **HTTP breadcrumb** carries the Supabase query string, which names
///   the table, the filters and the account.
///
/// So the rule is that the report describes the FAULT and never the figures.
/// This type is deliberately separate from `PaydayCrashReporting` and operates
/// on plain Sentry model objects, so every rule below is asserted by a test
/// that needs no DSN, no network and no running SDK. A scrubber that lived
/// inside an `SentrySDK.start` closure could not be tested at all, and an
/// untested privacy rule is a hope rather than a rule.
enum PaydayCrashScrubber {
    static let redaction = "[redacted]"

    /// Anything that looks like money, with a currency symbol in front of it.
    ///
    /// This is the belt-and-braces net for the strings this type cannot
    /// enumerate — a library's error text, an assertion message, a breadcrumb
    /// some future SDK version adds. It deliberately requires a currency
    /// symbol: redacting every bare number would also destroy the counts,
    /// indexes and status codes that make a crash diagnosable, and those are
    /// what the report exists for.
    ///
    /// Its limit, stated rather than hidden: a bare integer of cents in an
    /// error message is NOT caught. `fatalError("tips 24750 out of range")`
    /// would ship that number. The convention that covers the gap is that no
    /// error message in this app formats money into its text.
    /// Both separators are accepted in both roles, so `$1,284.09` and
    /// `€1.284,09` are each matched whole. Treating a comma as a possible
    /// decimal point means `€12,5` is redacted entirely rather than leaving
    /// `,5` behind — over-redacting, which is the safe direction. Grouping is
    /// required to be three digits, so a trailing comma that is punctuation
    /// rather than part of the number is left alone: `$40, and then` keeps its
    /// comma and its sentence.
    nonisolated(unsafe) private static let moneyPattern = try? NSRegularExpression(
        pattern: #"[$£€¥]\s?\d+(?:[.,]\d{3})*(?:[.,]\d{1,2})?"#
    )

    static func redactingMoney(in text: String) -> String {
        guard let moneyPattern else { return text }
        return moneyPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: redaction
        )
    }

    /// The path of a URL, with the query string removed.
    ///
    /// A Supabase read is `/rest/v1/shifts?user_id=eq.<uuid>&select=...`, so
    /// the query names the account and the columns while the path alone still
    /// tells you which table a failing request was for. The path is the part
    /// worth keeping.
    static func pathOnly(_ url: String) -> String {
        guard let components = URLComponents(string: url) else {
            return String(url.prefix(while: { $0 != "?" }))
        }
        var stripped = components
        stripped.query = nil
        stripped.fragment = nil
        return stripped.string ?? url
    }

    /// `nil` drops the breadcrumb entirely.
    static func scrub(_ crumb: Breadcrumb) -> Breadcrumb? {
        let category = crumb.category

        // Dropped outright rather than redacted. A UI breadcrumb's value IS
        // the name of the thing that was touched, and in this app that name is
        // usually an amount. Losing the tap trail costs some context when
        // reading a crash; keeping it would mean shipping the user's earnings
        // to diagnose a layout bug.
        if category.hasPrefix("ui.") || category == "touch" {
            return nil
        }

        if let message = crumb.message {
            crumb.message = redactingMoney(in: message)
        }

        if var data = crumb.data {
            if category == "http" || category == "network" {
                // A response body is never diagnostic enough to justify
                // carrying whatever it contains.
                for key in ["body", "request_body", "response_body", "data"] {
                    data.removeValue(forKey: key)
                }
                if let url = data["url"] as? String {
                    data["url"] = pathOnly(url)
                }
            }
            for (key, value) in data {
                if let text = value as? String {
                    data[key] = redactingMoney(in: text)
                }
            }
            crumb.data = data
        }

        return crumb
    }

    /// The last gate before an event leaves the device.
    static func scrub(_ event: Event) -> Event {
        // No id, no email, no username, no IP. Payday signs in with Apple, so
        // the identifier available to the SDK is the one thing that would turn
        // a crash report into a named person's finances. Nothing in this app
        // calls SentrySDK.setUser, and this makes that true even if something
        // later does.
        event.user = nil

        // The device's name is often the owner's name.
        event.serverName = nil

        if let request = event.request {
            request.queryString = nil
            request.cookies = nil
            if let url = request.url {
                request.url = pathOnly(url)
            }
            event.request = request
        }

        if let message = event.message {
            event.message = SentryMessage(formatted: redactingMoney(in: message.formatted))
        }

        if let exceptions = event.exceptions {
            for exception in exceptions {
                // Bridged from Objective-C, so nullable on read even though
                // the setter is not.
                if let value = exception.value as String? {
                    exception.value = redactingMoney(in: value)
                }
            }
        }

        if let extra = event.extra {
            var scrubbed = extra
            for (key, value) in extra {
                if let text = value as? String {
                    scrubbed[key] = redactingMoney(in: text)
                }
            }
            event.extra = scrubbed
        }

        // Breadcrumbs already passed through `beforeBreadcrumb` on the way in,
        // but a crash captured by the watchdog replays breadcrumbs the SDK
        // restored from disk, so they are filtered again on the way out.
        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrub($0) }
        }

        return event
    }
}
