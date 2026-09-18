import Foundation
import Sentry
import Testing
@testable import Payday

/// The privacy rules for crash reporting, asserted rather than assumed.
///
/// Every test here runs with no DSN, no network and no started SDK, which is
/// the reason `PaydayCrashScrubber` is a separate type operating on plain
/// Sentry model objects instead of a closure inside `SentrySDK.start`. The
/// rules are specific to an earnings app: the report has to describe the
/// fault and never the figures.
@Suite("Crash report scrubbing")
struct PaydayCrashScrubberTests {

    // MARK: - The money net

    @Test("a formatted amount is redacted wherever it appears in text")
    func moneyIsRedacted() {
        #expect(PaydayCrashScrubber.redactingMoney(in: "tapped $247.50")
            == "tapped [redacted]")
        #expect(PaydayCrashScrubber.redactingMoney(in: "total $1,284.09 for the week")
            == "total [redacted] for the week")
        // A comma is accepted as a decimal point too, so this redacts whole
        // rather than leaving ",5" behind. Over-redacting is the safe
        // direction for a figure.
        #expect(PaydayCrashScrubber.redactingMoney(in: "£40 and €12,5")
            == "[redacted] and [redacted]")
        #expect(PaydayCrashScrubber.redactingMoney(in: "€1.284,09 total")
            == "[redacted] total")
        #expect(PaydayCrashScrubber.redactingMoney(in: "$0")
            == "[redacted]")
    }

    /// Redacting every bare number would destroy the counts, indexes and
    /// status codes that make a crash diagnosable, which is what the report is
    /// for. So the net requires a currency symbol.
    @Test("numbers that are not money survive, because a crash needs them")
    func nonMoneyNumbersSurvive() {
        let text = "index 3 of 12 failed with 500 after 2 retries"
        #expect(PaydayCrashScrubber.redactingMoney(in: text) == text)
    }

    /// Thousands grouping is required to be three digits, so a comma that is
    /// punctuation rather than part of the number keeps its sentence readable.
    @Test("a comma after an amount is punctuation, not part of the figure")
    func trailingPunctuationSurvives() {
        #expect(PaydayCrashScrubber.redactingMoney(in: "paid $40, then failed")
            == "paid [redacted], then failed")
    }

    /// The stated limit of the net. A bare integer of cents is not caught, so
    /// the convention it relies on is that no error message in this app
    /// formats money into its text. Written as a test so the gap is a known
    /// one rather than a surprise.
    @Test("a bare cents integer is NOT caught, which is the documented gap")
    func bareCentsAreNotCaught() {
        #expect(PaydayCrashScrubber.redactingMoney(in: "tips 24750 out of range")
            == "tips 24750 out of range")
    }

    // MARK: - Breadcrumbs

    /// A UI breadcrumb's value IS the name of the element touched, and in this
    /// app that name is usually an amount. Dropped outright rather than
    /// redacted, because there is nothing left worth keeping.
    @Test("UI and touch breadcrumbs are dropped entirely")
    func uiBreadcrumbsAreDropped() {
        for category in ["ui.click", "ui.tap", "ui.lifecycle", "touch"] {
            let crumb = Breadcrumb()
            crumb.category = category
            crumb.message = "$247.50"
            #expect(PaydayCrashScrubber.scrub(crumb) == nil, "kept a \(category) breadcrumb")
        }
    }

    @Test("a navigation breadcrumb survives with its money redacted")
    func navigationBreadcrumbIsRedacted() throws {
        let crumb = Breadcrumb()
        crumb.category = "navigation"
        crumb.message = "opened period detail showing $1,284.09"
        let scrubbed = try #require(PaydayCrashScrubber.scrub(crumb))
        #expect(scrubbed.message == "opened period detail showing [redacted]")
    }

    /// A Supabase read is `/rest/v1/shifts?user_id=eq.<uuid>&select=...`. The
    /// query names the account and the columns; the path alone still says
    /// which table a failing request was for, which is the diagnostic part.
    @Test("an HTTP breadcrumb keeps its path and loses its query")
    func httpBreadcrumbLosesItsQuery() throws {
        let crumb = Breadcrumb()
        crumb.category = "http"
        crumb.data = [
            "url": "https://bkkxunqqfkogxibyyjmc.supabase.co/rest/v1/shifts?user_id=eq.11111111-1111-4111-8111-111111111111&select=cash_tips_cents",
            "method": "GET",
            "status_code": 500
        ]
        let scrubbed = try #require(PaydayCrashScrubber.scrub(crumb))
        let url = try #require(scrubbed.data?["url"] as? String)
        #expect(url == "https://bkkxunqqfkogxibyyjmc.supabase.co/rest/v1/shifts")
        #expect(!url.contains("user_id"))
        #expect(!url.contains("cash_tips_cents"))
        // The parts that make a failure readable are untouched.
        #expect(scrubbed.data?["method"] as? String == "GET")
        #expect(scrubbed.data?["status_code"] as? Int == 500)
    }

    /// A response body is never diagnostic enough to justify carrying whatever
    /// it contains, and for this app it contains rows of somebody's wages.
    @Test("a request or response body is removed, never redacted")
    func bodiesAreRemoved() throws {
        let crumb = Breadcrumb()
        crumb.category = "http"
        crumb.data = [
            "url": "https://example.supabase.co/rest/v1/shifts",
            "response_body": #"[{"cash_tips_cents":24750}]"#,
            "request_body": #"{"p_rows":[]}"#,
            "body": "anything"
        ]
        let scrubbed = try #require(PaydayCrashScrubber.scrub(crumb))
        #expect(scrubbed.data?["response_body"] == nil)
        #expect(scrubbed.data?["request_body"] == nil)
        #expect(scrubbed.data?["body"] == nil)
    }

    @Test("money in any breadcrumb data value is redacted")
    func breadcrumbDataIsRedacted() throws {
        let crumb = Breadcrumb()
        crumb.category = "app.lifecycle"
        crumb.data = ["headline": "Total $912.44", "count": 3]
        let scrubbed = try #require(PaydayCrashScrubber.scrub(crumb))
        #expect(scrubbed.data?["headline"] as? String == "Total [redacted]")
        #expect(scrubbed.data?["count"] as? Int == 3)
    }

    // MARK: - Events

    /// Payday signs in with Apple, so the identifier the SDK could attach is
    /// the one thing that would turn a crash report into a named person's
    /// finances. Nothing in this app calls `SentrySDK.setUser`; this makes the
    /// rule hold even if something later does.
    @Test("the user is stripped from every event")
    func userIsStripped() {
        let event = Event()
        let user = User()
        user.userId = "apple-sub-123"
        user.email = "tyler@example.com"
        user.ipAddress = "203.0.113.4"
        event.user = user

        #expect(PaydayCrashScrubber.scrub(event).user == nil)
    }

    /// A device's name is usually its owner's name.
    @Test("the device name is stripped")
    func serverNameIsStripped() {
        let event = Event()
        event.serverName = "Tyler's iPhone"
        #expect(PaydayCrashScrubber.scrub(event).serverName == nil)
    }

    @Test("an event's request loses its query string and cookies")
    func requestIsScrubbed() throws {
        let event = Event()
        let request = SentryRequest()
        request.url = "https://example.supabase.co/rest/v1/shifts?user_id=eq.abc"
        request.queryString = "user_id=eq.abc"
        request.cookies = "session=secret"
        event.request = request

        let scrubbed = PaydayCrashScrubber.scrub(event)
        let result = try #require(scrubbed.request)
        #expect(result.queryString == nil)
        #expect(result.cookies == nil)
        #expect(result.url == "https://example.supabase.co/rest/v1/shifts")
    }

    @Test("an exception message has its money redacted")
    func exceptionValueIsRedacted() throws {
        let event = Event()
        event.exceptions = [Exception(value: "expected $2,759.00 got $2,760.00", type: "Mismatch")]
        let scrubbed = PaydayCrashScrubber.scrub(event)
        let value = try #require(scrubbed.exceptions?.first?.value)
        #expect(value == "expected [redacted] got [redacted]")
    }

    @Test("an event message has its money redacted")
    func messageIsRedacted() throws {
        let event = Event()
        event.message = SentryMessage(formatted: "hero showed $0 while a row had $84.10")
        let scrubbed = PaydayCrashScrubber.scrub(event)
        #expect(scrubbed.message?.formatted == "hero showed [redacted] while a row had [redacted]")
    }

    /// A watchdog-terminated crash replays breadcrumbs the SDK restored from
    /// disk, which never passed through `beforeBreadcrumb` in this process. So
    /// the same filter runs again on the way out.
    @Test("breadcrumbs restored from disk are filtered again on the way out")
    func eventBreadcrumbsAreFilteredAgain() throws {
        let event = Event()
        let tap = Breadcrumb()
        tap.category = "ui.tap"
        tap.message = "$247.50"
        let nav = Breadcrumb()
        nav.category = "navigation"
        nav.message = "period detail $99.00"
        event.breadcrumbs = [tap, nav]

        let scrubbed = PaydayCrashScrubber.scrub(event)
        let crumbs = try #require(scrubbed.breadcrumbs)
        #expect(crumbs.count == 1)
        #expect(crumbs.first?.message == "period detail [redacted]")
    }

    @Test("a URL with no query is left alone")
    func pathOnlyIsIdempotent() {
        let url = "https://example.supabase.co/rest/v1/shifts"
        #expect(PaydayCrashScrubber.pathOnly(url) == url)
    }
}

/// The half that decides whether anything is collected at all.
@Suite("Crash reporting configuration")
struct PaydayCrashReportingTests {

    /// The whole mechanism by which Debug builds, unit tests and CI stay
    /// silent. No build flag does this; the absence of a DSN does.
    @Test("with no DSN in the bundle nothing is configured")
    func absentDSNMeansDisabled() {
        // This suite runs in a test build, where SENTRY_DSN is blank.
        #expect(PaydayCrashReporting.dsn == nil)
        #expect(!PaydayCrashReporting.isConfigured)
    }

    /// An unset xcconfig variable resolves to the literal `$(SENTRY_DSN)`
    /// rather than to nothing, and handing that to the SDK logs a parse
    /// failure on every launch instead of staying quiet.
    @Test("start() on an unconfigured build does nothing and does not crash")
    func startIsSafeWhenUnconfigured() {
        PaydayCrashReporting.start()
        #expect(!SentrySDK.isEnabled)
    }

    @Test("the release name is the form Sentry matches a dSYM against")
    func releaseNameIsSymbolicatable() {
        let name = PaydayCrashReporting.releaseName
        #expect(name.hasPrefix("payday@"))
        #expect(name.contains("+"))
    }

    @Test("a test build reports the debug environment")
    func environmentIsDebugUnderTest() {
        #expect(PaydayCrashReporting.environment == "debug")
    }

    /// Several of these are already the SDK's default. They are asserted
    /// anyway, because a default is a decision someone else gets to change in
    /// a minor version, and three of them cannot be undone after the fact: a
    /// screenshot, a view hierarchy and a transaction name are not strings
    /// this app gets to redact later.
    @Test("the options refuse every collection that cannot be redacted later")
    func optionsRefuseUnredactableCollection() {
        let options = Options()
        PaydayCrashReporting.configure(options, dsn: "https://abc@o1.ingest.sentry.io/1")

        #expect(options.sendDefaultPii == false)
        #expect(options.attachScreenshot == false)
        #expect(options.attachViewHierarchy == false)
        #expect(options.enableUserInteractionTracing == false)
        #expect(options.tracesSampleRate?.doubleValue == 0)
        #expect(options.enableCaptureFailedRequests == false)
        #expect(options.beforeSend != nil)
        #expect(options.beforeBreadcrumb != nil)
        #expect(options.maxBreadcrumbs == 50)
    }

    /// The options' own scrubbers must be the shared ones, or the tests above
    /// would be asserting rules that nothing actually applies.
    @Test("the configured scrubbers are the ones the tests above assert")
    func configuredScrubbersAreTheSharedOnes() throws {
        let options = Options()
        PaydayCrashReporting.configure(options, dsn: "https://abc@o1.ingest.sentry.io/1")

        let beforeBreadcrumb = try #require(options.beforeBreadcrumb)
        let tap = Breadcrumb()
        tap.category = "ui.tap"
        #expect(beforeBreadcrumb(tap) == nil)

        let beforeSend = try #require(options.beforeSend)
        let event = Event()
        let user = User()
        user.email = "tyler@example.com"
        event.user = user
        #expect(beforeSend(event)?.user == nil)
    }
}
