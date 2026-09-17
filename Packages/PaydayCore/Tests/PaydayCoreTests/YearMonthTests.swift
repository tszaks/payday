import Foundation
import Testing
@testable import PaydayCore

@Suite("YearMonth")
struct YearMonthTests {
    @Test("Month lengths respect leap years", arguments: [
        (2026, 1, 31), (2026, 2, 28), (2028, 2, 29), (2000, 2, 29), (1900, 2, 28),
        (2026, 4, 30), (2026, 9, 30), (2026, 12, 31),
    ])
    func dayCount(year: Int, month: Int, expected: Int) {
        let ym = YearMonth(year: year, month: month)
        #expect(ym.dayCount == expected)
        #expect(ym.range.count == expected)
        #expect(ym.range.start == CivilDay(year: year, month: month, day: 1))
        #expect(ym.range.end == CivilDay(year: year, month: month, day: expected))
    }

    @Test("next and previous wrap the year")
    func neighbours() {
        #expect(YearMonth(year: 2026, month: 12).next == YearMonth(year: 2027, month: 1))
        #expect(YearMonth(year: 2027, month: 1).previous == YearMonth(year: 2026, month: 12))
        #expect(YearMonth(year: 2026, month: 9).next.previous == YearMonth(year: 2026, month: 9))
    }

    @Test("Built from a day, and ordered")
    func fromDayAndOrdering() {
        let ym = YearMonth(CivilDay(year: 2026, month: 10, day: 4))
        #expect(ym == YearMonth(year: 2026, month: 10))
        #expect(YearMonth(year: 2026, month: 9) < ym)
        #expect(YearMonth(year: 2025, month: 12) < YearMonth(year: 2026, month: 1))
    }

    @Test("Two adjacent month ranges tile with no gap or overlap")
    func adjacentMonthsTile() {
        let sep = YearMonth(year: 2026, month: 9).range
        let oct = YearMonth(year: 2026, month: 10).range
        #expect(sep.end.adding(days: 1) == oct.start)
        #expect(sep.count + oct.count == 61)
    }

    @Test("Decoding an out-of-range month throws instead of trapping", arguments: [13, 0, -1, 99])
    func decodeRejectsBadMonth(month: Int) {
        let json = Data("{\"year\":2026,\"month\":\(month)}".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(YearMonth.self, from: json)
        }
    }

    @Test("A valid value round-trips through Codable")
    func codableRoundTrip() throws {
        let original = YearMonth(year: 2026, month: 9)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(YearMonth.self, from: data)
        #expect(decoded == original)
        #expect(decoded.dayCount == 30)

        let literal = Data("{\"year\":2028,\"month\":2}".utf8)
        #expect(try JSONDecoder().decode(YearMonth.self, from: literal) == YearMonth(year: 2028, month: 2))
    }
}
