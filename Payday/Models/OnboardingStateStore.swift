import Foundation

/// Owns the two facts that outlive the intro flow: whether it has been seen,
/// and the pay frequency the quiz already collected. Same UserDefaults-backed
/// pattern as `PayScheduleStore` and `UserPreferencesStore` — app
/// configuration, never a SwiftData record.
///
/// Deliberately narrow: the other quiz answers (shift load, tips per shift,
/// cash share, tracking method, goal) are NOT stored. No shipped feature reads
/// them, and persisting answers nothing consumes is just dead data that goes
/// stale. They exist for the length of the flow and are then dropped, the same
/// way Vero's `OnboardingViewModel.reset()` clears its own.
@Observable
final class OnboardingStateStore {
    private static let hasFinishedIntroKey = "com.szakacsmedia.payday.hasFinishedIntro"
    private static let quizPayFrequencyKey = "com.szakacsmedia.payday.quizPayFrequency"

    private let defaults: UserDefaults

    /// True once the person has been through the intro, or explicitly skipped
    /// it by saying they've used Payday before. Gates the pre-account branch of
    /// `RootView`, which sits ahead of `PaydayCloudGate`, so a new install
    /// sees the welcome before it is ever asked to sign in.
    var hasFinishedIntro: Bool {
        didSet { defaults.set(hasFinishedIntro, forKey: Self.hasFinishedIntroKey) }
    }

    /// The frequency picked during the quiz, handed forward so the setup screen
    /// doesn't ask the same question a second time (DESIGN.md rule 11). Nil for
    /// anyone who skipped the intro; the setup screen shows the picker then.
    var quizPayFrequency: PayFrequency? {
        didSet { persistQuizPayFrequency() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasFinishedIntro = defaults.bool(forKey: Self.hasFinishedIntroKey)
        self.quizPayFrequency = defaults.string(forKey: Self.quizPayFrequencyKey)
            .flatMap(PayFrequency.init(rawValue:))
    }

    /// Called once the pay schedule has actually been written, so a stale
    /// answer can never be re-applied to a schedule the person later edits.
    func clearQuizPayFrequency() {
        quizPayFrequency = nil
    }

    private func persistQuizPayFrequency() {
        if let quizPayFrequency {
            defaults.set(quizPayFrequency.rawValue, forKey: Self.quizPayFrequencyKey)
        } else {
            defaults.removeObject(forKey: Self.quizPayFrequencyKey)
        }
    }
}
