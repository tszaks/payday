import Foundation

/// One earnings or deduction line on a pay stub, as printed: its name, the
/// payroll system's category for it (lower case, "other" when none), and its
/// amount in cents.
public struct PayStubLine: Hashable, Sendable, Codable {
    public let name: String
    public let category: String
    public let cents: Int

    public init(name: String, category: String, cents: Int) {
        self.name = name
        self.category = category
        self.cents = cents
    }
}

/// What a pay stub's lines say about tips, gratuity and taxes: the figures an
/// imported paycheck carries. The one place these rules live; the payroll
/// server only reads the lines.
public struct PayStubFigures: Hashable, Sendable {
    /// Tips paid on this check. 0 when the stub lists earnings and none is a
    /// tip; nil when it lists no earnings at all (unknown, not zero).
    public let paidTipsCents: Int?
    /// Gratuity and service charge lines. Nil when there are none.
    public let gratuityCents: Int?
    /// Cash tips the person declared for tax. Already in their pocket, so
    /// never part of `paidTipsCents`. Nil when there are none.
    public let declaredTipsCents: Int?
    /// Taxes withheld: the federal, state, local, Social Security and
    /// Medicare lines. Nil when the stub has no tax line (not the same as
    /// zero tax).
    public let taxesCents: Int?

    public static let taxCategories: Set<String> = ["federal", "state", "local", "socialsec", "medicare"]

    public init(earnings: [PayStubLine], deductions: [PayStubLine]) {
        func sum(_ kind: EarningKind) -> Int? {
            let lines = earnings.filter { EarningKind(name: $0.name) == kind }
            return lines.isEmpty ? nil : lines.reduce(0) { $0 + $1.cents }
        }
        paidTipsCents = earnings.isEmpty ? nil : (sum(.tips) ?? 0)
        gratuityCents = sum(.gratuity)
        declaredTipsCents = sum(.declaredTips)
        let taxes = deductions.filter { Self.taxCategories.contains($0.category) }
        taxesCents = taxes.isEmpty ? nil : taxes.reduce(0) { $0 + abs($1.cents) }
    }

    /// What an earnings line is, from its name. Payroll systems name these
    /// lines freely ("CC Tips", "Tips - Credit Card", "Charged Tips", "Auto
    /// Gratuity", "Service Charge"), so the match is on the words that carry
    /// the meaning. The rules, in the order they are tried:
    ///
    /// 1. Not a tip, though the word is there: "tip credit", "tip makeup",
    ///    "tip adjustment" are the employer's minimum-wage accounting (FLSA
    ///    3(m)), wages rather than tips. "Tips Credit Card" is not one of
    ///    them: "credit" there names the card the tips came on.
    /// 2. Gratuity: "gratuity", "gratuities", "grat", "service charge". A
    ///    mandatory charge the employer distributes; Payday keeps it apart
    ///    from tips.
    /// 3. Declared tips: a tip line that says "cash", "declared" or
    ///    "reported". On the stub so it can be taxed; not paid by this check.
    /// 4. Tips: any other line with "tip" or "tips" as a word ("Credit Card
    ///    Tips", "Tips Paid", "Tip Share").
    public enum EarningKind: Hashable, Sendable {
        case tips
        case declaredTips
        case gratuity
        case other

        public init(name: String?) {
            let text = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.contains(Self.notTipsPattern) {
                self = .other
            } else if text.contains(Self.gratuityPattern) {
                self = .gratuity
            } else if text.contains(Self.tipPattern) {
                self = text.contains(Self.declaredPattern) ? .declaredTips : .tips
            } else {
                self = .other
            }
        }

        // Built per call: a Regex is not Sendable, so it cannot be a stored
        // static under Swift 6.
        private static var notTipsPattern: Regex<Substring> {
            #/\btips?\s*(?:credit(?!\s*cards?\b)|make\s*-?\s*up|adj(?:ustment)?)\b/#.ignoresCase()
        }

        private static var gratuityPattern: Regex<Substring> {
            #/\b(?:gratuit(?:y|ies)|grat|service\s*charges?|auto\s*-?\s*grat)\b/#.ignoresCase()
        }

        private static var declaredPattern: Regex<Substring> {
            #/\b(?:cash|declared|reported)\b/#.ignoresCase()
        }

        private static var tipPattern: Regex<Substring> {
            #/\btips?\b/#.ignoresCase()
        }
    }
}
