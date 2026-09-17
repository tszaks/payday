import Foundation
import Testing

/// The release gate: no fixture may still be a known issue when a release
/// ships. `swift test` has no way to skip a tag (`--skip` matches test names,
/// not tags), so the per-PR run and the release run execute the same test and
/// the environment decides how strict it is (see docs/CI.md):
///
/// - `PAYDAYCORE_RELEASE_GATE=1`: assert `KnownIssues.all` is empty. Fails.
/// - otherwise: pass. When the list is non-empty the passing expectation's
///   message names the pending IDs so they appear in the log, but nothing is
///   recorded as a known issue: the fixture tests themselves already record
///   one per listed ID via `expectingKnownIssues(for:)`, and a second
///   `withKnownIssue` here would count as unrecorded once the list is empty.
@Suite("Known-issue release gate", .tags(.releaseGate))
struct KnownIssuesGateTests {
    static var gateArmed: Bool {
        ProcessInfo.processInfo.environment["PAYDAYCORE_RELEASE_GATE"] == "1"
    }

    @Test("knownIssueCountIsZero")
    func knownIssueCountIsZero() {
        let pending = KnownIssues.all
        if Self.gateArmed {
            #expect(pending.isEmpty, "Release blocked: known issues pending \(pending). See docs/METRICS.md.")
        } else if pending.isEmpty {
            #expect(pending.isEmpty)
        } else {
            // Unarmed and pending: a plain pass whose message lists what is still open.
            #expect(
                !pending.isEmpty,
                "Release gate not armed (PAYDAYCORE_RELEASE_GATE != 1); \(pending.count) known issue(s) pending: \(pending.joined(separator: ", ")). See docs/METRICS.md."
            )
        }
    }

    @Test("KnownIssues.json entries are fixture IDs, not paths or blanks")
    func entriesAreWellFormed() {
        for id in KnownIssues.all {
            #expect(!id.isEmpty)
            #expect(!id.contains("/"))
            #expect(!id.hasSuffix(".json"))
        }
    }

    /// The shrink guarantee only holds for IDs some test actually wraps in
    /// `expectingKnownIssues(for:)`: an ID nothing wraps would sit on the list
    /// forever and only the armed release gate would ever notice.
    /// `FixtureConsistencyTests.everyFixtureConverts` is parameterized over
    /// every fixture in the bundle and wraps each case, so "listed" implies
    /// "wrapped" exactly when every listed ID names a present fixture. That is
    /// what this asserts, and it holds regardless of test execution order.
    @Test("Every listed known issue names a present fixture, so a wrapped test claims it")
    func everyKnownIssueIsClaimedByAWrappedTest() {
        let available = Set(FixtureLoader.availableIDs())
        #expect(!available.isEmpty, "no fixtures in the bundle: the claim below would be vacuous")
        for id in KnownIssues.all {
            #expect(
                available.contains(id),
                "KnownIssues.json lists \(id), which is not a fixture in the bundle, so no test wraps it in expectingKnownIssues(for:) and it can never go red on its own. Remove it or add the fixture."
            )
        }
    }
}
