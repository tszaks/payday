import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("Payday copy — tense-honest payDateText")
struct PaydayCopyTests {
    @Test("a future payday reads 'Payday · <weekday>, <date>'")
    func futurePaydayReadsUpcoming() {
        let text = PaydayCopy.payDateText(payDate: date(2026, 7, 29), relativeTo: date(2026, 7, 20))
        #expect(text.hasPrefix("Payday ·"))
        #expect(!text.contains("Paid"))
    }

    @Test("today's payday still reads 'Payday', not 'Paid' — the money hasn't landed yet at any point today")
    func todaysPaydayReadsUpcoming() {
        let text = PaydayCopy.payDateText(payDate: date(2026, 7, 20), relativeTo: date(2026, 7, 20))
        #expect(text.hasPrefix("Payday ·"))
    }

    @Test("a past payday reads 'Paid <date>'")
    func pastPaydayReadsPaid() {
        let text = PaydayCopy.payDateText(payDate: date(2026, 7, 10), relativeTo: date(2026, 7, 20))
        #expect(text == "Paid Jul 10")
    }

    @Test("a long-past payday (last month) still reads 'Paid <date>', no different from a recent one")
    func longPastPaydayReadsPaid() {
        let text = PaydayCopy.payDateText(payDate: date(2026, 6, 24), relativeTo: date(2026, 7, 20))
        #expect(text == "Paid Jun 24")
    }
}
