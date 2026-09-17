import Foundation
import Testing

/// The known-issue gate. `Fixtures/KnownIssues.json` is a JSON array of
/// fixture IDs whose tests cannot pass yet. A fixture test for a listed ID
/// wraps its assertions in `withKnownIssue` (use `expectingKnownIssues(for:)`)
/// so CI stays green and honest: the failure is recorded as a known issue,
/// not hidden. `KnownIssuesGateTests.knownIssueCountIsZero` asserts the list
/// is empty when `PAYDAYCORE_RELEASE_GATE=1` (the release workflow, PR 8).
///
/// The list must shrink as fixtures go green, in the ordinary run and not
/// only at release: `withKnownIssue` (without `isIntermittent: true`) records
/// a `knownIssueNotRecorded` issue and FAILS the run when its body passes, so
/// listing an ID whose test already passes is itself a failure. That bites for
/// every listed ID because
/// `FixtureConsistencyTests.everyFixtureConverts` is parameterized over every
/// fixture in the bundle and wraps each case in `expectingKnownIssues(for:)`,
/// and `KnownIssuesGateTests.everyKnownIssueIsClaimedByAWrappedTest` fails on
/// a listed ID that is not a fixture in the bundle (the only way to escape
/// that wrapper). Remove the ID from `KnownIssues.json` in the same PR that
/// makes its fixture pass.
enum KnownIssues {
    static let fileName = "KnownIssues"

    /// The listed fixture IDs, in file order. Traps if the file is missing or
    /// malformed: a gate that cannot read its list is not a gate.
    static let all: [String] = {
        guard let url = Bundle.module.url(forResource: fileName, withExtension: "json", subdirectory: FixtureLoader.directory) else {
            fatalError("Fixtures/KnownIssues.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        } catch {
            fatalError("Fixtures/KnownIssues.json is not a JSON array of strings: \(error)")
        }
    }()

    static func isKnownIssue(_ id: String) -> Bool {
        all.contains(id)
    }
}

/// Runs `body`; when `id` is listed in `KnownIssues.json` the body is wrapped
/// in `withKnownIssue("<id> pending: see docs/METRICS.md")` so its failures
/// are recorded as known rather than failing the run. If the body passes
/// while `id` is still listed, the wrapper records `knownIssueNotRecorded`
/// and the run fails: that is the signal to delete the ID from the list.
func expectingKnownIssues(for id: String, _ body: () throws -> Void) throws {
    if KnownIssues.isKnownIssue(id) {
        withKnownIssue("\(id) pending: see docs/METRICS.md") {
            try body()
        }
    } else {
        try body()
    }
}

extension Tag {
    /// Tests that only mean something for a release build (PR 8 release workflow).
    @Tag static var releaseGate: Self
}
