import Testing
import Foundation
import SwiftData
@testable import Payday

/// Regression coverage for the 2026-09-14 security review. Each suite below
/// names the finding it pins down, so a future refactor that reopens one of
/// these holes fails here rather than in the next review.

@Suite("Authorization policy shared across processes (findings 2, 4, 8)")
struct PaydayAuthorizationStateTests {

    // MARK: - The predicates

    @Test("an explicit sign-out withdraws every kind of access")
    func signOutWithdrawsEverything() {
        #expect(!PaydayAuthorizationState.allowsFinancialAccess(isExplicitlySignedOut: true))
        #expect(!PaydayAuthorizationState.allowsAmbientDisclosure(
            isExplicitlySignedOut: true,
            isAppLockEnabled: false
        ))
        #expect(!PaydayAuthorizationState.allowsAmbientDisclosure(
            isExplicitlySignedOut: true,
            isAppLockEnabled: true
        ))
    }

    @Test("an enabled app lock stops ambient disclosure but not on-request access")
    func appLockStopsAmbientOnly() {
        // Someone who turned the lock on has said their earnings need
        // authentication, so a widget must not print them. An intent still
        // may, because the platform requires an unlocked device for those.
        #expect(!PaydayAuthorizationState.allowsAmbientDisclosure(
            isExplicitlySignedOut: false,
            isAppLockEnabled: true
        ))
        #expect(PaydayAuthorizationState.allowsFinancialAccess(isExplicitlySignedOut: false))
    }

    @Test("a signed-in device with no lock allows both")
    func signedInAllowsBoth() {
        #expect(PaydayAuthorizationState.allowsFinancialAccess(isExplicitlySignedOut: false))
        #expect(PaydayAuthorizationState.allowsAmbientDisclosure(
            isExplicitlySignedOut: false,
            isAppLockEnabled: false
        ))
    }

    // MARK: - Persistence round trip

    @Test("the sign-out marker survives, and only a fresh sign-in clears it")
    func signOutMarkerRoundTrips() {
        let wasSignedOut = PaydayAuthorizationState.isExplicitlySignedOut
        let wasLocked = PaydayAuthorizationState.isAppLockEnabled
        defer {
            if wasSignedOut {
                PaydayAuthorizationState.markExplicitlySignedOut()
            } else {
                PaydayAuthorizationState.clearExplicitSignOut()
            }
            PaydayAuthorizationState.setAppLockEnabled(wasLocked)
        }

        PaydayAuthorizationState.clearExplicitSignOut()
        #expect(PaydayAuthorizationState.allowsFinancialAccess)

        PaydayAuthorizationState.markExplicitlySignedOut()
        #expect(PaydayAuthorizationState.isExplicitlySignedOut)
        // This is the finding: a cold restart used to read a missing session
        // as "refresh the JWT" and restore the cache. The marker is what
        // makes "deliberately left" durable and distinguishable.
        #expect(!PaydayAuthorizationState.allowsFinancialAccess)
        #expect(!PaydayAuthorizationState.allowsAmbientDisclosure)

        PaydayAuthorizationState.clearExplicitSignOut()
        #expect(PaydayAuthorizationState.allowsFinancialAccess)
    }

    @Test("reset clears both flags, for the account-deletion path")
    func resetClearsEverything() {
        let wasSignedOut = PaydayAuthorizationState.isExplicitlySignedOut
        let wasLocked = PaydayAuthorizationState.isAppLockEnabled
        defer {
            if wasSignedOut {
                PaydayAuthorizationState.markExplicitlySignedOut()
            } else {
                PaydayAuthorizationState.clearExplicitSignOut()
            }
            PaydayAuthorizationState.setAppLockEnabled(wasLocked)
        }

        PaydayAuthorizationState.markExplicitlySignedOut()
        PaydayAuthorizationState.setAppLockEnabled(true)

        PaydayAuthorizationState.reset()

        #expect(!PaydayAuthorizationState.isExplicitlySignedOut)
        #expect(!PaydayAuthorizationState.isAppLockEnabled)
    }
}

@Suite("Forgetting a deleted account (finding 5)")
struct PaydaySyncStateForgetTests {

    @Test("forgetting the registered account frees the device for a different Apple ID")
    func forgetClearsRegistration() {
        let original = PaydaySyncState.registeredUserID
        defer {
            if let original {
                PaydaySyncState.registerCurrentUser(original)
            }
        }

        let deleted = UUID()
        PaydaySyncState.forget(userID: original ?? UUID())
        #expect(PaydaySyncState.registerCurrentUser(deleted))
        #expect(PaydaySyncState.registeredUserID == deleted)

        PaydaySyncState.forget(userID: deleted)

        // The lockout this fixes: canRegister only admits a user when none is
        // registered or it is the same one, so a leftover registration from a
        // DELETED account refused the next Apple ID with accountMismatch.
        #expect(PaydaySyncState.registeredUserID == nil)
        let replacement = UUID()
        #expect(PaydaySyncState.canRegister(userID: replacement, registeredUserID: PaydaySyncState.registeredUserID))
        #expect(PaydaySyncState.registerCurrentUser(replacement))

        PaydaySyncState.forget(userID: replacement)
    }

    @Test("forgetting one account leaves a different registered account alone")
    func forgetIsScopedToItsAccount() {
        let original = PaydaySyncState.registeredUserID
        defer {
            PaydaySyncState.forget(userID: PaydaySyncState.registeredUserID ?? UUID())
            if let original {
                PaydaySyncState.registerCurrentUser(original)
            }
        }

        PaydaySyncState.forget(userID: original ?? UUID())
        let active = UUID()
        #expect(PaydaySyncState.registerCurrentUser(active))

        PaydaySyncState.forget(userID: UUID())

        #expect(PaydaySyncState.registeredUserID == active)
    }
}

@Suite("CSV export keeps untrusted text inert (finding 6)")
struct CSVFormulaNeutralizationTests {

    /// The note column, straight out of a real export. Index 13 — see
    /// CSVExporter.header.
    private func noteCell(_ note: String) -> String {
        let day = Date(timeIntervalSince1970: 1_780_000_000)
        let calculator = PayPeriodCalculator(
            schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: Date(timeIntervalSince1970: 1_779_000_000))
        )
        let entry = TipEntry(date: day, amountCents: 5_000, kind: .cash, note: note)
        let csv = CSVExporter.export(entries: [entry], paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        return fields[13]
    }

    @Test("every formula trigger is neutralized with a leading apostrophe")
    func formulaTriggersAreNeutralized() {
        // A write-scoped agent key can store any of these as a note, and the
        // exported file then carries a live formula into Excel or Sheets.
        for trigger in ["=", "+", "-", "@"] {
            let cell = noteCell("\(trigger)1+1")
            #expect(cell.hasPrefix("'"), "\(trigger) was not neutralized: \(cell)")
        }
    }

    @Test("leading whitespace does not smuggle a formula past the check")
    func leadingWhitespaceIsHandled() {
        // Spreadsheets trim leading spaces before deciding whether a cell is
        // a formula, so the check has to trim too.
        let cell = noteCell("   =1+1")
        #expect(cell.hasPrefix("'"))
    }

    @Test("a formula that also needs quoting gets both treatments")
    func formulaAndCommaTogether() {
        let cell = noteCell("=HYPERLINK(\"x\",\"y\")")
        #expect(cell.hasPrefix("\"'"), "expected a quoted, neutralized cell, got: \(cell)")
    }

    @Test("ordinary notes are left exactly as written")
    func ordinaryNotesUnchanged() {
        #expect(noteCell("Busy Friday") == "Busy Friday")
        #expect(noteCell("Table 12 tipped well") == "Table 12 tipped well")
    }
}
