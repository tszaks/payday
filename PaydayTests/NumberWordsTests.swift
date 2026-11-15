import Testing
import Foundation
@testable import Payday

/// Counts in prose are spelled; digits belong to money and clock times. The
/// sentence that forced the rule read "Only 5 5PM starts to compare against
/// so far," where a count digit butted straight against a time digit.
@Suite("Number words")
struct NumberWordsTests {
    @Test("small counts spell out")
    func spellsSmallCounts() {
        #expect(NumberWords.spell(1) == "one")
        #expect(NumberWords.spell(5) == "five")
        #expect(NumberWords.spell(24) == "twenty-four")
    }

    @Test("above the ceiling, digits read better than words")
    func digitsAboveCeiling() {
        #expect(NumberWords.spell(100) == "100")
        #expect(NumberWords.spell(143) == "143")
    }

    @Test("negatives fall back to digits rather than producing prose")
    func negativeFallsBack() {
        #expect(NumberWords.spell(-3) == "-3")
    }

    @Test("a count never lands adjacent to a clock time as two digits")
    func noDigitCollisionWithClockTime() {
        // The exact regression: five 5 PM starts.
        let phrase = "Only \(NumberWords.spell(5)) 5 PM starts to compare against so far."
        #expect(phrase == "Only five 5 PM starts to compare against so far.")
        #expect(!phrase.contains("5 5"))
    }
}
