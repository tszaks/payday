import Testing
import Foundation
@testable import Payday

@Suite("LogTipsIntent shift targeting")
struct LogTipsIntentTargetShiftIDTests {
    @Test("completes today's shift when it's missing the requested kind")
    func appendsToExistingShift() {
        let shiftID = UUID()
        let existing: [(shiftID: UUID?, kind: TipKind, recordedAt: Date?)] = [
            (shiftID: shiftID, kind: .cash, recordedAt: .now)
        ]
        #expect(LogTipsIntent.targetShiftID(existingToday: existing, kind: .credit) == shiftID)
    }

    @Test("mints a new shift when today's shift already has that kind")
    func mintsNewWhenKindAlreadyPresent() {
        let shiftID = UUID()
        let existing: [(shiftID: UUID?, kind: TipKind, recordedAt: Date?)] = [
            (shiftID: shiftID, kind: .cash, recordedAt: .now)
        ]
        #expect(LogTipsIntent.targetShiftID(existingToday: existing, kind: .cash) == nil)
    }

    @Test("mints a new shift when nothing was logged today")
    func mintsNewOnEmptyDay() {
        #expect(LogTipsIntent.targetShiftID(existingToday: [], kind: .cash) == nil)
    }

    @Test("legacy rows with no shiftID are never completed into")
    func ignoresNilShiftIDRows() {
        let existing: [(shiftID: UUID?, kind: TipKind, recordedAt: Date?)] = [
            (shiftID: nil, kind: .cash, recordedAt: .now)
        ]
        #expect(LogTipsIntent.targetShiftID(existingToday: existing, kind: .credit) == nil)
    }

    @Test("with more than one shift already today, targets the most recently recorded one")
    func picksMostRecentShiftAmongMultiple() {
        let earlierShift = UUID()
        let laterShift = UUID()
        let existing: [(shiftID: UUID?, kind: TipKind, recordedAt: Date?)] = [
            (shiftID: earlierShift, kind: .cash, recordedAt: Date(timeIntervalSince1970: 100)),
            (shiftID: laterShift, kind: .cash, recordedAt: Date(timeIntervalSince1970: 200))
        ]
        #expect(LogTipsIntent.targetShiftID(existingToday: existing, kind: .credit) == laterShift)
    }
}
