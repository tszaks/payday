import Testing
import Foundation
@testable import Payday

@Suite("LiveShiftEndModeResolver")
struct LiveShiftEndModeTests {
    @Test("adopts the live session's punches when creating with a live session")
    func adoptsLiveSessionWhenCreating() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        let now = start.addingTimeInterval(3600)
        let mode = LiveShiftEndModeResolver.resolve(isEditing: false, providedClockIn: nil, providedClockOut: nil, activeStart: start, now: now)
        #expect(mode == LiveShiftEndMode(clockIn: start, clockOut: now))
    }

    @Test("clockOut is exactly the passed now")
    func clockOutIsExactlyNow() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        let now = start.addingTimeInterval(1_234)
        let mode = LiveShiftEndModeResolver.resolve(isEditing: false, providedClockIn: nil, providedClockOut: nil, activeStart: start, now: now)
        #expect(mode?.clockOut == now)
    }

    @Test("nil while editing an existing shift")
    func nilWhileEditing() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        let mode = LiveShiftEndModeResolver.resolve(isEditing: true, providedClockIn: nil, providedClockOut: nil, activeStart: start)
        #expect(mode == nil)
    }

    @Test("nil when the target already provides explicit punches")
    func nilWithExplicitPunches() {
        let start = Date(timeIntervalSince1970: 1_753_500_000)
        let providedIn = start.addingTimeInterval(-100)
        let providedOut = start.addingTimeInterval(100)
        let mode = LiveShiftEndModeResolver.resolve(isEditing: false, providedClockIn: providedIn, providedClockOut: providedOut, activeStart: start)
        #expect(mode == nil)
    }

    @Test("nil with no active session")
    func nilWithNoSession() {
        let mode = LiveShiftEndModeResolver.resolve(isEditing: false, providedClockIn: nil, providedClockOut: nil, activeStart: nil)
        #expect(mode == nil)
    }
}
