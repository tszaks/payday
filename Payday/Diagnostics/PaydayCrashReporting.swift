import Foundation
import Sentry

/// Sentry, started once, or not at all.
///
/// The DSN comes from `SENTRY_DSN` in the bundle, and when it is absent or
/// empty NOTHING starts: no SDK, no network, no disk. That is the whole
/// mechanism by which Debug builds, unit tests and CI stay silent, and it
/// needs no build flags to do it. `isConfigured` reads exactly like
/// `InsightsService.isConfigured` does for the narration key.
///
/// A DSN is not a secret, which is worth stating because this repo treats the
/// OpenAI key as one. A Sentry DSN is a write-only ingest key designed to be
/// embedded in a shipped client — it can send events and read nothing — so it
/// lives in `project.yml` alongside `SUPABASE_PUBLISHABLE_KEY` rather than in
/// the gitignored `Secrets.local.xcconfig`. It is blank today only because the
/// Sentry project does not exist yet; see docs/SENTRY.md.
enum PaydayCrashReporting {
    private static let dsnKey = "SENTRY_DSN"

    static var dsn: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: dsnKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset xcconfig variable resolves to the literal `$(SENTRY_DSN)`
        // rather than to nothing, and handing that to the SDK logs a parse
        // failure on every launch instead of staying quiet.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), trimmed.hasPrefix("http") else {
            return nil
        }
        return trimmed
    }

    static var isConfigured: Bool { dsn != nil }

    /// Called first thing in `PaydayApp.init`, which is the earliest point the
    /// app controls — early enough to catch a failure opening the shared
    /// SwiftData container, which is the one startup crash this app has
    /// actually shipped a recovery screen for.
    static func start() {
        guard let dsn, !isRunningTests else { return }
        SentrySDK.start { options in
            configure(options, dsn: dsn)
        }
    }

    /// A test host launches the app for real, so without this a DSN would make
    /// the suite report its own deliberate failures as production crashes.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Split out of `start` so a test can assert the settings without a DSN,
    /// a network or a running SDK. Several of these are already the SDK's
    /// default; they are set anyway, because a default is a decision someone
    /// else gets to change in a minor version.
    static func configure(_ options: Options, dsn: String) {
        options.dsn = dsn
        options.releaseName = releaseName
        options.environment = environment

        // --- What must never be collected -------------------------------
        // See PaydayCrashScrubber for why each of these matters more here
        // than it would in most apps.
        options.sendDefaultPii = false
        // A screenshot of Payday is a picture of somebody's wages, and unlike
        // a string it cannot be redacted after the fact.
        options.attachScreenshot = false
        // A view hierarchy carries accessibility labels, which in this app are
        // formatted amounts.
        options.attachViewHierarchy = false
        // A user-interaction transaction is NAMED after the element tapped,
        // and the element is called "$247.50".
        options.enableUserInteractionTracing = false
        // No performance data at all. Payday has no latency question worth
        // answering with traces, and a transaction name is another place a
        // screen's contents can leak.
        options.tracesSampleRate = 0
        options.enableCaptureFailedRequests = false

        // --- The scrubbers ----------------------------------------------
        options.beforeBreadcrumb = { crumb in PaydayCrashScrubber.scrub(crumb) }
        options.beforeSend = { event in PaydayCrashScrubber.scrub(event) }

        // Enough trail to read a crash, not enough to reconstruct a session.
        options.maxBreadcrumbs = 50
        options.debug = false
    }

    /// `payday@1.0+9142029`, which is the form Sentry matches against an
    /// uploaded dSYM, so a release named any other way symbolicates to
    /// nothing.
    static var releaseName: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "payday@\(short)+\(build)"
    }

    static var environment: String {
        #if DEBUG
        "debug"
        #else
        "production"
        #endif
    }
}
