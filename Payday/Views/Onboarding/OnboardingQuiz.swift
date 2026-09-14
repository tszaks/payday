import Foundation

// MARK: - Stage

/// Stage progression for the pre-account intro: a single-question quiz, a short
/// beat while the answers are turned into arithmetic, then a personalized
/// reveal. Ported from Vero's `OnboardingStage` so the two apps' first runs
/// share one shape (see docs/DESIGN.md, "The Family Contract").
///
/// Lives entirely inside `OnboardingFlowView` under the pre-gate branch of
/// `RootView`, which is evaluated BEFORE `PaydayCloudGate` — so the quiz is
/// unreachable for anyone who already has a session, by construction.
enum PaydayOnboardingStage: String, CaseIterable {
    case welcome
    case shifts
    case tips
    case cash
    case tracking
    case goal
    case frequency
    case analyzing
    case reveal

    /// The six question stages, in display order. Drives the progress dots.
    static let questionStages: [PaydayOnboardingStage] = [
        .shifts, .tips, .cash, .tracking, .goal, .frequency
    ]

    /// 1-based position among the question stages (nil for welcome/analyzing/reveal).
    var questionNumber: Int? {
        PaydayOnboardingStage.questionStages.firstIndex(of: self).map { $0 + 1 }
    }

    var next: PaydayOnboardingStage? {
        let all = PaydayOnboardingStage.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    var previous: PaydayOnboardingStage? {
        let all = PaydayOnboardingStage.allCases
        guard let i = all.firstIndex(of: self), i - 1 >= 0 else { return nil }
        return all[i - 1]
    }
}

// MARK: - Quiz Answers

/// How many shifts the person works in a normal week. Feeds the projection
/// arithmetic only — never persisted, since no shipped feature reads it.
enum ShiftLoad: String, CaseIterable, Identifiable {
    case oneTwo = "1-2"
    case threeFour = "3-4"
    case fiveSix = "5-6"
    case sevenPlus = "7+"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneTwo: "1 or 2"
        case .threeFour: "3 or 4"
        case .fiveSix: "5 or 6"
        case .sevenPlus: "7 or more"
        }
    }

    /// Fixed midpoint used by the projection. Never a measurement.
    var shiftsPerWeek: Double {
        switch self {
        case .oneTwo: 1.5
        case .threeFour: 3.5
        case .fiveSix: 5.5
        case .sevenPlus: 7
        }
    }

    /// Arithmetic the reader would otherwise do themselves (DESIGN.md rule 11:
    /// a derived fact earns its line, a restated one does not).
    var microInsight: String {
        let shiftsAYear = Int((shiftsPerWeek * 52 / 10).rounded()) * 10
        switch self {
        case .sevenPlus:
            return "That's around \(shiftsAYear) shifts a year. Payday keeps every one."
        default:
            return "That's around \(shiftsAYear) shifts a year to keep track of."
        }
    }
}

/// What the person typically walks out with after one shift. Feeds the
/// projection arithmetic only — never persisted.
enum TipsPerShift: String, CaseIterable, Identifiable {
    case underHundred = "under_100"
    case hundredToTwo = "100_200"
    case twoToThree = "200_300"
    case overThree = "300_plus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .underHundred: "Under $100"
        case .hundredToTwo: "$100 to $200"
        case .twoToThree: "$200 to $300"
        case .overThree: "More than $300"
        }
    }

    /// Fixed midpoint in whole dollars. The open-ended bands use the nearest
    /// defensible edge value, never an optimistic guess past it.
    var midpointDollars: Int {
        switch self {
        case .underHundred: 75
        case .hundredToTwo: 150
        case .twoToThree: 250
        case .overThree: 350
        }
    }

    var microInsight: String {
        switch self {
        case .underHundred: "Payday will show you which nights beat that."
        case .hundredToTwo: "Most people can't name their best night. You will."
        case .twoToThree: "Good nights and bad ones average out. Payday shows the spread."
        case .overThree: "At that rate, one unlogged shift is real money missing."
        }
    }
}

/// How much of the tip income arrives as cash. This is the fact that makes
/// Payday matter: cash is the part no pay stub ever records.
enum CashShare: String, CaseIterable, Identifiable {
    case almostNone = "almost_none"
    case quarter
    case half
    case most

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .almostNone: "Almost none"
        case .quarter: "About a quarter"
        case .half: "About half"
        case .most: "Most of it"
        }
    }

    var fraction: Double {
        switch self {
        case .almostNone: 0
        case .quarter: 0.25
        case .half: 0.5
        case .most: 0.75
        }
    }

    var microInsight: String {
        switch self {
        case .almostNone: "Then your stubs tell most of the story. Payday tells the rest."
        case .quarter: "Cash is the part that never shows up on a pay stub."
        case .half: "Half your income leaves no paper trail behind it."
        case .most: "Almost none of what you earn appears on a stub."
        }
    }
}

/// How the person tracks tips today. Not persisted — it exists so the
/// "Payday does this for you" note lands as relief rather than a sales line.
enum TipTrackingMethod: String, CaseIterable, Identifiable {
    case nothing
    case head
    case notesApp = "notes_app"
    case paper
    case anotherApp = "another_app"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nothing: "I don't"
        case .head: "In my head"
        case .notesApp: "Notes app"
        case .paper: "Paper or a notebook"
        case .anotherApp: "Another app"
        }
    }

    var microInsight: String {
        switch self {
        case .nothing: "No judgment. Most people don't."
        case .head: "Payday remembers every night, so you don't have to."
        case .notesApp: "Payday does the arithmetic your notes can't."
        case .paper: "Paper works right up until you want a total."
        case .anotherApp: "See if this one takes you under ten seconds."
        }
    }
}

/// What the person wants out of the app. Every option maps to a feature that
/// actually ships, so the reveal never promises something that isn't there.
enum PaydayGoal: String, CaseIterable, Identifiable {
    case realIncome = "real_income"
    case worthwhileShifts = "worthwhile_shifts"
    case checkAccuracy = "check_accuracy"
    case improvement

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realIncome: "What I actually make"
        case .worthwhileShifts: "Which shifts are worth working"
        case .checkAccuracy: "Whether my check is right"
        case .improvement: "Whether I'm getting better"
        }
    }

    /// The shipped surface that answers this. Shown on the reveal.
    var promise: String {
        switch self {
        case .realIncome: "Your dashboard answers that with one number, every day."
        case .worthwhileShifts: "Payday ranks your nights by weekday, so you can see which shifts really pay."
        case .checkAccuracy: "Payday predicts your check's tips line, then checks the real stub against it."
        case .improvement: "Payday keeps your records and shows the trend, period over period."
        }
    }
}

/// Derived subtitle for the pay-frequency choices. Lives here rather than on
/// `PayFrequency` itself so the shared model stays free of onboarding copy.
extension PayFrequency {
    var onboardingSubtitle: String {
        switch self {
        case .weekly: "52 checks a year"
        case .biweekly: "26 checks a year"
        case .twiceMonthly: "1st–15th and 16th–month end"
        case .monthly: "12 checks a year"
        }
    }
}

// MARK: - Diagnosis

/// A personalized, deterministic reading computed purely from quiz answers.
/// No network, no AI, no `Date`, no randomness — the same answers always
/// produce an `Equatable`-equal value, so it is unit-testable and every number
/// on the reveal agrees with every other one.
///
/// Substantiation rule, inherited from Vero: a dollar figure must be
/// ORIGINATED by something the person actually told us. Here it is
/// `shifts per week × tips per shift × 52` — their own two numbers multiplied.
/// When either is missing, the reveal stays qualitative rather than inventing
/// a number the inputs don't support.
struct PaydayOnboardingDiagnosis: Equatable {
    /// Headline above the figure. Never contains the figure itself — the
    /// count-up already says it (DESIGN.md rule 11, "say it once").
    let headline: String
    /// Projected annual tip income in whole dollars. 0 means "not
    /// substantiated" and suppresses the count-up entirely.
    let projectedAnnualTips: Int
    /// Caption under the figure, stating the basis out loud.
    let projectionCaption: String
    /// The cash reading — Payday's reason to exist.
    let cashLine: String?
    /// What the app will do about the goal they picked.
    let secondaryInsight: String?

    static func compute(
        shifts: ShiftLoad?,
        tips: TipsPerShift?,
        cash: CashShare?,
        tracking: TipTrackingMethod?,
        goal: PaydayGoal?
    ) -> PaydayOnboardingDiagnosis {
        guard let shifts, let tips else {
            return PaydayOnboardingDiagnosis(
                headline: "Payday keeps the record of every shift, so you always know what you actually make.",
                projectedAnnualTips: 0,
                projectionCaption: "",
                cashLine: cash?.microInsight,
                secondaryInsight: goal?.promise ?? tracking?.microInsight
            )
        }

        // Their two numbers, multiplied out over a year. Rounded to the
        // nearest $500 so it reads as the estimate it is, and clamped so a
        // band edge can never produce an absurd headline figure.
        let raw = shifts.shiftsPerWeek * Double(tips.midpointDollars) * 52
        let rounded = Int((raw / 500).rounded()) * 500
        let projected = min(max(rounded, 3_000), 130_000)

        return PaydayOnboardingDiagnosis(
            headline: "Here's what a year of your shifts looks like.",
            projectedAnnualTips: projected,
            projectionCaption: "in tips a year, at the pace you just described",
            cashLine: makeCashLine(cash: cash, projectedAnnualTips: projected),
            secondaryInsight: goal?.promise
        )
    }

    // MARK: - Static copy tables (deterministic)

    private static func makeCashLine(cash: CashShare?, projectedAnnualTips: Int) -> String? {
        guard let cash else { return nil }
        guard cash.fraction > 0 else {
            // Nothing to quantify: don't assert a cash figure for someone who
            // said they barely take any. The paycheck check is the real
            // promise for this person, and it ships.
            return "Almost all of it runs through your checks. Payday tells you when one of them comes up short."
        }
        let cashDollars = Int(((Double(projectedAnnualTips) * cash.fraction) / 500).rounded()) * 500
        let amount = Money.wholeDollarString(fromCents: cashDollars * 100)
        return "Around \(amount) of that is cash. Cash leaves no pay stub behind it, so Payday is the only record you'll have of it."
    }
}
