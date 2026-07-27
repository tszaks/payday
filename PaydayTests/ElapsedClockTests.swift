import Testing
import Foundation
@testable import Payday

@Suite("ElapsedClock")
struct ElapsedClockTests {
    private let start = Date(timeIntervalSince1970: 1_753_500_000)

    @Test("always reads H:MM:SS, from the first second")
    func underAnHour() {
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(0)) == "0:00:00")
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(7)) == "0:00:07")
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(47 * 60 + 5)) == "0:47:05")
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(3599)) == "0:59:59")
    }

    @Test("past the hour the hour digit grows unpadded")
    func hourAndBeyond() {
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(3600)) == "1:00:00")
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(3600 + 69 * 60 + 43)) == "2:09:43")
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(12 * 3600 + 1)) == "12:00:01")
    }

    @Test("a clock-skewed negative elapsed clamps to zero")
    func negativeClampsToZero() {
        #expect(ElapsedClock.string(from: start, to: start.addingTimeInterval(-30)) == "0:00:00")
    }
}
