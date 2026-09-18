import Foundation

// MARK: - Stage

/// Stage progression for the pre-account intro: a single-question quiz, a short
/// beat while the answers are turned into arithmetic, then a personalized
/// reveal. Ported from Vero's `OnboardingStage` so the two apps' first runs
/// share one shape (see docs/DESIGN.md, "The Family Contract").
///
/// Rendered by `PaydayCloudGate`'s signed-out branch, which makes the welcome
/// screen the app's ONE front door: if you are not signed in, this is what you
/// see, whether it is your first launch or you just signed out. The flow ends
/// at `.account`, which hosts the Sign in with Apple button itself — so there
/// is no second, plainer sign-in screen to fall through to.
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
    case account

    /// The six question stages, in display order. Drives the progress dots.
    static let questionStages: [PaydayOnboardingStage] = [
        .shifts, .tips, .cash, .tracking, .goal, .frequency
    ]

    /// 1-based position among the question stages (nil for welcome/analyzing/reveal).
    var questionNumber: Int? {
        PaydayOnboardingStage.questionStages.firstIndex(of: self).map { $0 + 1 }
    }

    /// True for the six stages that render inside `OnboardingQuizShell`.
    var isQuestion: Bool { questionNumber != nil }

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

// MARK: - Projection

/// The onboarding projection: a dollar figure that is **deliberately not an
/// engine figure**, and the only place in Payday where that is true.
///
/// ## The decision, and why (PR 5 group 2.9, 2026-09-18)
///
/// `docs/METRICS.md` rows [OB-02], [OB-03], [OB-04] and [OB-05] are the only
/// currency figures in the app with no `MetricID`. The choice was to route
/// them through the engine or to keep them synthetic and label them as such.
/// **They stay synthetic**, on purpose, for three reasons:
///
/// 1. **There is nothing for the engine to read.** This screen runs before
///    sign-in and before the first shift exists: no `TipEntry`, no
///    `ShiftRecord`, no `CompensationPolicies`, no `EarningsSnapshot`. The
///    only way to produce an `EarningsResult` here would be to fabricate
///    shifts out of two dropdown bands and hand them to
///    `CompensationLedger`.
/// 2. **That would make the engine attest a guess.** An `EarningsResult`
///    carries a `SnapshotStamp` and a `Completeness`: it is the app's promise
///    that a number came from records. `PAYDAYCORE_GOAL.md`'s governing rule
///    is that one metric returns the same cents on every consumer — a
///    projection from band midpoints is not a metric, it has no other
///    consumer to agree with, and stamping it would make "this came from the
///    engine" stop meaning anything.
/// 3. **Nothing else in the app shows annual tips.** There is no surface this
///    figure can contradict. The one figure that DOES have a twin — the
///    payday notification against the Dashboard's card — is reconciled in
///    `PaydayPushScheduler`, and it is reconciled because it has a twin.
///
/// So the labelling is the whole job, and it is structural rather than a
/// comment: this type is the ONE place the projection arithmetic lives, it is
/// the ONE place onboarding turns whole dollars into currency text, it cannot
/// be constructed from an `EarningsSnapshot`, and it deliberately exposes no
/// `stamp`, no `Completeness` and no `MetricID` — so a reviewer grepping for
/// figures that bypassed the engine finds this type and its recorded reason
/// rather than a loose `* 52` in a view.
///
/// Every figure it produces is spoken with its basis out loud ("in tips a
/// year, at the pace you just described"), which is the substantiation rule
/// this file's diagnosis already carried.
struct OnboardingProjection: Equatable {
    /// Projected annual tips in whole dollars. 0 means "the answers do not
    /// substantiate a figure", and suppresses the count-up entirely.
    let annualTipsDollars: Int
    /// The cash share of the projection, in whole dollars. Nil when the
    /// person said almost none arrives as cash, which is a sentence rather
    /// than a figure.
    let cashDollars: Int?

    /// Not substantiated: either band is missing, so no figure is asserted.
    static let unsubstantiated = OnboardingProjection(annualTipsDollars: 0, cashDollars: nil)

    /// Their own two numbers multiplied out over a year, rounded to the
    /// nearest $500 so it reads as the estimate it is, and clamped so a band
    /// edge can never produce an absurd headline figure.
    ///
    /// This is the only multiplication in the onboarding flow. It is here,
    /// and not in `PaydayOnboardingDiagnosis` (a facts struct) or in
    /// `OnboardingRevealView` (a view), because those are the two places the
    /// PR 5 adapter contract forbids money arithmetic outright.
    static func from(shifts: ShiftLoad?, tips: TipsPerShift?, cash: CashShare?) -> OnboardingProjection {
        guard let shifts, let tips else { return .unsubstantiated }
        let raw = shifts.shiftsPerWeek * Double(tips.midpointDollars) * 52
        let annual = min(max(roundedToHalfThousand(raw), 3_000), 130_000)
        guard let cash, cash.fraction > 0 else {
            return OnboardingProjection(annualTipsDollars: annual, cashDollars: nil)
        }
        return OnboardingProjection(
            annualTipsDollars: annual,
            cashDollars: roundedToHalfThousand(Double(annual) * cash.fraction)
        )
    }

    private static func roundedToHalfThousand(_ dollars: Double) -> Int {
        Int((dollars / 500).rounded()) * 500
    }

    // MARK: Text

    /// The ONE place a whole-dollar onboarding figure becomes currency text.
    ///
    /// Not `EarningsFigure` — that type exists so a view cannot print a
    /// figure it computed itself, and its whole contract (a `MetricID` from
    /// the registry, a label the completeness rules allow, `nil` text for an
    /// unavailable read) is about figures the engine answered. Borrowing it
    /// for a projection would say the opposite of what this type is for. The
    /// suppression rule here is the analogous one, stated in the type that
    /// owns it: `annualTipsDollars == 0` renders no figure at all, which is
    /// why `OnboardingRevealView` gates the count-up on it.
    static func text(wholeDollars: Int) -> String {
        Money.wholeDollarString(fromCents: wholeDollars * 100)
    }

    /// The settled figure, or nil when the answers substantiate none.
    var annualTipsText: String? {
        guard annualTipsDollars > 0 else { return nil }
        return Self.text(wholeDollars: annualTipsDollars)
    }

    /// One frame of the count-up, from the view's animated progress.
    ///
    /// The easing is MOTION, so it stays in the view; turning an already
    /// projected figure's frame into text is not a second figure and the
    /// intermediate values are never a fact about anybody (they are never
    /// whole-$500 like the target, and VoiceOver reads `annualTipsText`
    /// instead — [OB-04]).
    func countUpText(displayedDollars: Double) -> String {
        Self.text(wholeDollars: Int(displayedDollars.rounded()))
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
///
/// **It holds no money arithmetic.** Every figure on it comes from
/// `OnboardingProjection`, which owns the multiplication and carries the
/// recorded decision that these figures are intentionally not engine figures
/// (PR 5 adapter contract, rule 1: a facts struct keeps only presentation).
/// This struct's job is the words.
struct PaydayOnboardingDiagnosis: Equatable {
    /// Headline above the figure. Never contains the figure itself — the
    /// count-up already says it (DESIGN.md rule 11, "say it once").
    let headline: String
    /// The synthetic projection this reading is written around. Not an
    /// engine figure, by decision: see `OnboardingProjection`.
    let projection: OnboardingProjection
    /// Caption under the figure, stating the basis out loud.
    let projectionCaption: String
    /// The cash reading — Payday's reason to exist.
    let cashLine: String?
    /// What the app will do about the goal they picked.
    let secondaryInsight: String?

    /// Projected annual tip income in whole dollars. 0 means "not
    /// substantiated" and suppresses the count-up entirely.
    var projectedAnnualTips: Int { projection.annualTipsDollars }

    static func compute(
        shifts: ShiftLoad?,
        tips: TipsPerShift?,
        cash: CashShare?,
        tracking: TipTrackingMethod?,
        goal: PaydayGoal?
    ) -> PaydayOnboardingDiagnosis {
        let projection = OnboardingProjection.from(shifts: shifts, tips: tips, cash: cash)
        guard projection.annualTipsDollars > 0 else {
            return PaydayOnboardingDiagnosis(
                headline: "Payday keeps the record of every shift, so you always know what you actually make.",
                projection: projection,
                projectionCaption: "",
                cashLine: cash?.microInsight,
                secondaryInsight: goal?.promise ?? tracking?.microInsight
            )
        }

        return PaydayOnboardingDiagnosis(
            headline: "Here's what a year of your shifts looks like.",
            projection: projection,
            projectionCaption: "in tips a year, at the pace you just described",
            cashLine: makeCashLine(cash: cash, projection: projection),
            secondaryInsight: goal?.promise
        )
    }

    // MARK: - Static copy tables (deterministic)

    private static func makeCashLine(cash: CashShare?, projection: OnboardingProjection) -> String? {
        guard cash != nil else { return nil }
        guard let cashDollars = projection.cashDollars else {
            // Nothing to quantify: don't assert a cash figure for someone who
            // said they barely take any. The paycheck check is the real
            // promise for this person, and it ships.
            return "Almost all of it runs through your checks. Payday tells you when one of them comes up short."
        }
        let amount = OnboardingProjection.text(wholeDollars: cashDollars)
        return "Around \(amount) of that is cash. Cash leaves no pay stub behind it, so Payday is the only record you'll have of it."
    }
}
