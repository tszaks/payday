import Foundation

/// Spells a COUNT as a word — "five shifts", not "5 shifts".
///
/// Tyler's rule (2026-08-05): digits are reserved for money and clock times,
/// so a count in prose is spelled out. The sentence that forced it read "Only
/// 5 5PM starts to compare against so far," where a count digit sat directly
/// against a time digit and read as one number. Spelling the count removes the
/// collision by construction rather than by hoping the two never touch.
///
/// Applies to PROSE only. Stat-tile captions ("6 shifts" under LUNCH) stay in
/// digits — those are data labels sitting under a number, not sentences.
enum NumberWords {
    /// Above this, digits are clearer than words: "one hundred twenty-three
    /// shifts" is worse prose than "123 shifts", and a count that large can't
    /// collide with a 12-hour clock time anyway.
    private static let spellOutCeiling = 99

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        return formatter
    }()

    /// "five", "twenty-four", "123". Locale-aware via NumberFormatter rather
    /// than a hand-rolled English table.
    static func spell(_ count: Int) -> String {
        guard count >= 0, count <= spellOutCeiling,
              let spelled = formatter.string(from: NSNumber(value: count))
        else { return "\(count)" }
        return spelled
    }

    /// "five shifts" / "one shift" — the one place prose pairs a spelled count
    /// with its noun.
    static func phrase(_ count: Int, singular: String, plural: String) -> String {
        "\(spell(count)) \(count == 1 ? singular : plural)"
    }
}
