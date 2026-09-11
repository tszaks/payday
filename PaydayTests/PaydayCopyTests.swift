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

@Suite("Widget directional comparisons")
struct WidgetDirectionalTests {
    @Test("Losses use a down arrow; gains use an up arrow; zero stays neutral")
    func signedAmounts() {
        #expect(Money.directionalDeltaString(fromCents: -88593) == "↓ \(Money.string(fromCents: 88593))")
        #expect(Money.directionalDeltaString(fromCents: 20000) == "↑ \(Money.string(fromCents: 20000))")
        #expect(Money.directionalDeltaString(fromCents: -1) == "↓ \(Money.string(fromCents: 1))")
        #expect(Money.directionalDeltaString(fromCents: 0) == Money.string(fromCents: 0))
    }

    @Test("Large comparisons keep their full magnitude without overflowing")
    func largeAmounts() {
        #expect(Money.directionalDeltaString(fromCents: -123456789) == "↓ \(Money.string(fromCents: 123456789))")
        #expect(Money.directionalDeltaString(fromCents: Int.min).hasPrefix("↓ "))
    }
}
