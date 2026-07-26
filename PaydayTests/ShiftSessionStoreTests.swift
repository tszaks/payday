import Testing
import Foundation
@testable import Payday

@Suite("ShiftSessionStore")
final class ShiftSessionStoreTests {
    // These write to the REAL App Group suite the installed app reads, so
    // cleanup runs on the way out as well as in: a leftover pendingEnd
    // otherwise greets the next app launch on that simulator with a
    // prefilled log sheet for a shift that only ever existed in a fixture.
    init() { Self.clear() }
    deinit { Self.clear() }

    private static func clear() {
        AppGroup.defaults.removeObject(forKey: "activeShiftStartedAt")
        AppGroup.defaults.removeObject(forKey: "pendingEndedShift")
    }

    @Test("start sets activeStart")
    func startSetsActiveStart() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        ShiftSessionStore.start(at: start)
        #expect(ShiftSessionStore.activeStart == start)
    }

    @Test("starting twice keeps the first date")
    func startTwiceKeepsFirstDate() {
        let first = Date(timeIntervalSince1970: 1_753_500_000)
        let second = first.addingTimeInterval(600)
        ShiftSessionStore.start(at: first)
        ShiftSessionStore.start(at: second)
        #expect(ShiftSessionStore.activeStart == first)
    }

    @Test("endActive returns the pair, clears active, and stashes pendingEnd")
    func endActiveReturnsPairAndStashesPendingEnd() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        let end = start.addingTimeInterval(3600)
        ShiftSessionStore.start(at: start)
        let pair = ShiftSessionStore.endActive(at: end)
        #expect(pair?.start == start)
        #expect(pair?.end == end)
        #expect(ShiftSessionStore.activeStart == nil)
        #expect(ShiftSessionStore.pendingEnd?.start == start)
        #expect(ShiftSessionStore.pendingEnd?.end == end)
    }

    @Test("popPendingEnd returns once then nil")
    func popPendingEndReturnsOnceThenNil() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        let end = start.addingTimeInterval(1800)
        ShiftSessionStore.start(at: start)
        ShiftSessionStore.endActive(at: end)

        let first = ShiftSessionStore.popPendingEnd()
        #expect(first?.start == start)
        #expect(first?.end == end)
        #expect(ShiftSessionStore.popPendingEnd() == nil)
    }

    @Test("endActive with nothing active returns nil and stashes nothing")
    func endActiveWithNothingActiveReturnsNilAndStashesNothing() {
        #expect(ShiftSessionStore.endActive() == nil)
        #expect(ShiftSessionStore.pendingEnd == nil)
    }

    @Test("pendingEnd round-trips exact dates")
    func pendingEndRoundTripsExactDates() {
        let start = Date(timeIntervalSince1970: 1_753_500_123.456)
        let end = Date(timeIntervalSince1970: 1_753_530_654.789)
        ShiftSessionStore.start(at: start)
        ShiftSessionStore.endActive(at: end)

        let pending = ShiftSessionStore.pendingEnd
        #expect(pending?.start == start)
        #expect(pending?.end == end)
    }
}
