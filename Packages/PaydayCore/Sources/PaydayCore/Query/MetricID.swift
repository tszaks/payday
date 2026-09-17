import Foundation

/// The metric registry. Every number Payday shows, speaks, exports, or
/// serves has exactly one of these identities, and `docs/METRICS.md` maps
/// every consumer (screen, intent, widget face, notification, export, API
/// endpoint) to one. A number without a `MetricID` is a bug.
///
/// Each case documents its definition, its basis (which date buckets it),
/// its missing-data rule, and the only labels it may be presented under.
/// The registry is a contract: adding a case means adding a row to
/// `docs/METRICS.md` and a presentation rule in `CompletenessCopy`.
public enum MetricID: String, CaseIterable, Codable, Sendable {
    /// **Definition:** cash + credit + gratuityFees - tipOut + regularWages + overtimeWages.
    /// **Basis:** work date.
    /// **Missing data:** wages are absent where the ledger says `.unavailable`;
    /// the result carries `Completeness` and the presentation rules for
    /// `.partial` apply ("Known so far", hollow bars, "N of M shifts").
    /// **Labels:** "Total" (complete), "Known so far" (partial), "Earned",
    /// "You kept" (when tipOut > 0).
    case earnedIncome

    /// **Definition:** cash + credit + gratuityFees - tipOut (earned income without wages).
    /// **Basis:** work date.
    /// **Missing data:** none; every shift has tips.
    /// **Labels:** "Tips" when gratuity == 0, otherwise "Tips & gratuity".
    case nonWageEarnings

    /// **Definition:** cash + credit (tips the guest chose to leave).
    /// **Basis:** work date.
    /// **Missing data:** none.
    /// **Labels:** today's drawer rows "Cash tips" and "Credit tips", plus "Tips"
    /// for the combined figure. The entry-field captions "Cash" and "Credit" are
    /// input labels, not metric labels, and are not in this list.
    case voluntaryTips

    /// **Definition:** service charges and auto-gratuity, never mixed into voluntary tips.
    /// **Basis:** work date.
    /// **Missing data:** none.
    /// **Labels:** today's drawer row "Gratuity & fees" only. The entry-field
    /// caption "Gratuity" is an input label, not a metric label.
    case gratuityFees

    /// **Definition:** cents the server paid out to support staff; subtracted once per shift.
    /// **Basis:** work date.
    /// **Missing data:** none (nil tip-out counts as 0).
    /// **Labels:** today's drawer row "Tipped out".
    case tipOut

    /// **Definition:** hourlyRateCents × regular minutes under the workweek threshold, cumulative half-up rounding per week.
    /// **Basis:** work date.
    /// **Missing data:** `.unavailable` when hours or rate are missing; rolls into `Completeness`.
    /// **Labels:** today's drawer row "Wages · {hours}" (e.g. "Wages · 6h 23m"); `{hours}`
    /// is the placeholder for the formatted regular hours, like `$X`/`N`/`M` in `hourlyRate`.
    case regularWages

    /// **Definition:** hourlyRateCents × multiplier × minutes past the workweek threshold, cumulative half-up rounding per week.
    /// **Basis:** work date.
    /// **Missing data:** `.unavailable` when hours or rate are missing; rolls into `Completeness`.
    /// **Labels:** today's drawer row "Overtime · {hours}" (e.g. "Overtime · 2h"); `{hours}`
    /// is the placeholder for the formatted overtime hours.
    case overtimeWages

    /// **Definition:** max(0, (credit > 0 ? credit : cash + credit) - tipOut); the stub never
    /// prints a negative tips line (today's `PredictedPaycheck.tipsLineCents`). Cash never runs
    /// through payroll, so cash only enters the line when no credit was logged at all.
    /// **Basis:** pay period.
    /// **Missing data:** none.
    /// **Labels:** "Your check's tips line".
    case expectedPaycheckTipsLine

    /// **Definition:** expectedPaycheckTipsLine + gratuityFees + regularWages + overtimeWages.
    /// **Basis:** pay period.
    /// **Missing data:** wages `.unavailable` are absent and the result carries `Completeness`.
    /// **Labels:** "Expected".
    case expectedPaycheckGross

    /// **Definition:** the paid-tips figure on the real pay stub, exactly as entered. Never altered by the engine.
    /// **Basis:** pay date.
    /// **Missing data:** nil until a paycheck is recorded.
    /// **Labels:** "Paid".
    case observedPaidTips

    /// **Definition:** an inferred ±100c correction to observedPaidTips (stub field misread), kept separate and never auto-applied.
    /// **Basis:** pay date.
    /// **Missing data:** nil when no correction is inferred.
    /// **Labels:** "Looks like $X (accept?)".
    case proposedPaidTipsCorrection

    /// **Definition:** observed - expected, per component, for one pay period.
    /// **Basis:** pay period.
    /// **Missing data:** never added to income; absent components produce no delta.
    /// **Labels:** "checked"; red only when < 0.
    case reconciliationDelta

    /// **Definition:** Σ earnedIncome over covered shifts (those with hours) × 60 / Σ minutes over covered shifts, half-up.
    /// **Basis:** the query's range.
    /// **Missing data:** nil without coverage (minutes == 0); shifts without hours are excluded from BOTH numerator and denominator; carries N of M.
    /// **Labels:** "Averaging $X/hr · N of M shifts".
    case hourlyRate

    /// One-line definition from the registry table.
    public var definition: String {
        switch self {
        case .earnedIncome:
            return "cash + credit + gratuityFees - tipOut + regularWages + overtimeWages"
        case .nonWageEarnings:
            return "cash + credit + gratuityFees - tipOut (earned income without wages)"
        case .voluntaryTips:
            return "cash + credit"
        case .gratuityFees:
            return "service charges and auto-gratuity, separate from voluntary tips"
        case .tipOut:
            return "cents paid out to support staff, subtracted once per shift"
        case .regularWages:
            return "hourlyRateCents x regular minutes under the workweek threshold, cumulative half-up rounding per week"
        case .overtimeWages:
            return "hourlyRateCents x multiplier x minutes past the workweek threshold, cumulative half-up rounding per week"
        case .expectedPaycheckTipsLine:
            return "max(0, (credit > 0 ? credit : cash + credit) - tipOut); the stub never prints a negative tips line (today's PredictedPaycheck.tipsLineCents)"
        case .expectedPaycheckGross:
            return "expectedPaycheckTipsLine + gratuityFees + regularWages + overtimeWages"
        case .observedPaidTips:
            return "paid-tips figure on the real pay stub, exactly as entered"
        case .proposedPaidTipsCorrection:
            return "inferred +/-100c correction to observedPaidTips, separate, never auto-applied"
        case .reconciliationDelta:
            return "observed - expected, per component, for one pay period"
        case .hourlyRate:
            return "sum earnedIncome over covered shifts x 60 / sum minutes over covered shifts, half-up"
        }
    }

    /// Which date buckets the metric.
    public var basis: MetricBasis {
        switch self {
        case .earnedIncome, .nonWageEarnings, .voluntaryTips, .gratuityFees, .tipOut,
             .regularWages, .overtimeWages:
            return .workDate
        case .expectedPaycheckTipsLine, .expectedPaycheckGross, .reconciliationDelta:
            return .payPeriod
        case .observedPaidTips, .proposedPaidTipsCorrection:
            return .payDate
        case .hourlyRate:
            return .queryRange
        }
    }

    /// What happens when an input is missing.
    public var missingDataRule: String {
        switch self {
        case .earnedIncome, .expectedPaycheckGross:
            return "wages absent where .unavailable; result carries Completeness"
        case .regularWages, .overtimeWages:
            return ".unavailable when hours or rate are missing; rolls into Completeness"
        case .nonWageEarnings, .voluntaryTips, .gratuityFees, .expectedPaycheckTipsLine:
            return "none"
        case .tipOut:
            return "none (nil tip-out counts as 0)"
        case .observedPaidTips:
            return "nil until a paycheck is recorded"
        case .proposedPaidTipsCorrection:
            return "nil when no correction is inferred"
        case .reconciliationDelta:
            return "never added to income; absent components produce no delta"
        case .hourlyRate:
            return "nil without coverage; uncovered shifts excluded from both sides; carries N of M"
        }
    }

    /// The only labels this metric may be presented under. Copy tests assert
    /// every adapter label is a member of this list. Labels containing a
    /// placeholder (`$X`, `N`, `M`, `{hours}`) match after the adapter's
    /// formatted value is substituted back out.
    public var allowedLabels: [String] {
        switch self {
        case .earnedIncome:
            return ["Total", "Known so far", "Earned", "You kept"]
        case .nonWageEarnings:
            return ["Tips", "Tips & gratuity"]
        case .voluntaryTips:
            return ["Cash tips", "Credit tips", "Tips"]
        case .gratuityFees:
            return ["Gratuity & fees"]
        case .tipOut:
            return ["Tipped out"]
        case .regularWages:
            return ["Wages · {hours}"]
        case .overtimeWages:
            return ["Overtime · {hours}"]
        case .expectedPaycheckTipsLine:
            return ["Your check's tips line"]
        case .expectedPaycheckGross:
            return ["Expected"]
        case .observedPaidTips:
            return ["Paid"]
        case .proposedPaidTipsCorrection:
            return ["Looks like $X (accept?)"]
        case .reconciliationDelta:
            return ["checked"]
        case .hourlyRate:
            return ["Averaging $X/hr · N of M shifts"]
        }
    }
}

/// The date a metric is bucketed by.
public enum MetricBasis: String, Codable, Sendable {
    /// The shift's civil work day.
    case workDate
    /// The pay period the shift falls in.
    case payPeriod
    /// The paycheck's pay date.
    case payDate
    /// Whatever range the query asked for.
    case queryRange
}
