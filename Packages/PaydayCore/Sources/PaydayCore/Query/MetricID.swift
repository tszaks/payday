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
    /// **Definition:** cash + credit + gratuityFees + tipShareIn - tipOut + regularWages + overtimeWages.
    /// **Basis:** work date.
    /// **Missing data:** wages are absent where the ledger says `.unavailable`;
    /// the result carries `Completeness` and the presentation rules for
    /// `.partial` apply ("Known so far", hollow bars, "N of M shifts").
    /// **Labels:** "Total" (complete), "Known so far" (partial), "Earned",
    /// "You kept" (when tipOut > 0).
    case earnedIncome

    /// **Definition:** cash + credit + gratuityFees + tipShareIn - tipOut (earned income without wages).
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

    /// **Definition:** cents received from co-workers as a tip share or pool payout; added once per shift. Never part of voluntaryTips.
    /// **Basis:** work date.
    /// **Missing data:** none (nil tip share counts as 0).
    /// **Labels:** the drawer row "Tip share received".
    case tipShareIn

    /// **Definition:** hourlyRateCents × regular minutes under the workweek threshold, cumulative half-up rounding per week.
    /// **Basis:** work date.
    /// **Missing data:** `.unavailable` when hours or rate are missing; rolls into `Completeness`.
    /// **Labels:** the drawer row "Wages". The regular hours are no longer part
    /// of the label -- they ride on the row's CAPTION ("9h 45m"), because a
    /// label carrying a duration and a cell carrying a dollar amount, in one
    /// weight on one line, made the reader work out which half was the money.
    /// A caption is not a label, so it is not registered here; the row's
    /// figure is still the only thing this metric may be titled with.
    case regularWages

    /// **Definition:** hourlyRateCents × multiplier × minutes past the workweek threshold, cumulative half-up rounding per week.
    /// **Basis:** work date.
    /// **Missing data:** `.unavailable` when hours or rate are missing; rolls into `Completeness`.
    /// **Labels:** the drawer row "Overtime". As with `regularWages`, the hours
    /// moved to the row's caption and out of the label.
    case overtimeWages

    /// **Definition:** 0 when card tips are paid at close; otherwise
    /// max(0, (credit + tipShareIn > 0 ? credit + tipShareIn : cash + credit) - tipOut); the stub never
    /// prints a negative tips line (today's `PredictedPaycheck.tipsLineCents`). Cash never runs
    /// through payroll, so cash only enters the line when no credit or tip share was logged at all.
    /// **Basis:** pay period.
    /// **Missing data:** none.
    /// **Labels:** "Your check's tips line".
    case expectedPaycheckTipsLine

    /// **Definition:** expectedPaycheckTipsLine + gratuityFees + regularWages + overtimeWages
    /// (gratuityFees + wages when card tips are paid at close).
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

    /// **Definition:** the gross figure on the real pay stub, exactly as entered. Never inferred.
    /// **Basis:** pay date.
    /// **Missing data:** nil until a paycheck with a gross is recorded.
    /// **Labels:** "Gross Income".
    case observedGross

    /// **Definition:** the net figure on the real pay stub, exactly as entered. Never inferred.
    /// **Basis:** pay date.
    /// **Missing data:** nil until a paycheck with a net is recorded.
    /// **Labels:** "Net Income".
    case observedNet

    /// **Definition:** the taxes figure on the real pay stub, exactly as entered. Never inferred.
    /// **Basis:** pay date.
    /// **Missing data:** nil until a paycheck with taxes is recorded.
    /// **Labels:** "Taxes".
    case observedTaxes

    /// **Definition:** expectedPaycheckGross passed through the WithholdingModel fitted on the person's last 8 stubs that have both gross and net.
    /// **Basis:** pay period.
    /// **Missing data:** .unavailable when the gross is unavailable or fewer than 2 stubs qualify; carries the gross figure's Completeness.
    /// **Labels:** "After tax, about"; caption nil unless it warns: "Outside the checks it has seen" when extrapolating, then the gross figure's completeness caption. Never a stub count.
    case expectedPaycheckNet

    /// One-line definition from the registry table.
    public var definition: String {
        switch self {
        case .earnedIncome:
            return "cash + credit + gratuityFees + tipShareIn - tipOut + regularWages + overtimeWages"
        case .nonWageEarnings:
            return "cash + credit + gratuityFees + tipShareIn - tipOut (earned income without wages)"
        case .voluntaryTips:
            return "cash + credit"
        case .gratuityFees:
            return "service charges and auto-gratuity, separate from voluntary tips"
        case .tipOut:
            return "cents paid out to support staff, subtracted once per shift"
        case .tipShareIn:
            return "cents received from co-workers as a tip share or pool payout, added once per shift; never part of voluntaryTips"
        case .regularWages:
            return "hourlyRateCents x regular minutes under the workweek threshold, cumulative half-up rounding per week"
        case .overtimeWages:
            return "hourlyRateCents x multiplier x minutes past the workweek threshold, cumulative half-up rounding per week"
        case .expectedPaycheckTipsLine:
            return "0 when card tips are paid at close; otherwise max(0, (credit + tipShareIn > 0 ? credit + tipShareIn : cash + credit) - tipOut); the stub never prints a negative tips line (today's PredictedPaycheck.tipsLineCents)"
        case .expectedPaycheckGross:
            return "expectedPaycheckTipsLine + gratuityFees + regularWages + overtimeWages (gratuityFees + wages when card tips are paid at close)"
        case .observedPaidTips:
            return "paid-tips figure on the real pay stub, exactly as entered"
        case .proposedPaidTipsCorrection:
            return "inferred +/-100c correction to observedPaidTips, separate, never auto-applied"
        case .reconciliationDelta:
            return "observed - expected, per component, for one pay period"
        case .hourlyRate:
            return "sum earnedIncome over covered shifts x 60 / sum minutes over covered shifts, half-up"
        case .observedGross:
            return "gross figure on the real pay stub, exactly as entered"
        case .observedNet:
            return "net figure on the real pay stub, exactly as entered"
        case .observedTaxes:
            return "taxes figure on the real pay stub, exactly as entered"
        case .expectedPaycheckNet:
            return "expectedPaycheckGross through the WithholdingModel fitted on the last 8 stubs with gross and net"
        }
    }

    /// Which date buckets the metric.
    public var basis: MetricBasis {
        switch self {
        case .earnedIncome, .nonWageEarnings, .voluntaryTips, .gratuityFees, .tipOut, .tipShareIn,
             .regularWages, .overtimeWages:
            return .workDate
        case .expectedPaycheckTipsLine, .expectedPaycheckGross, .reconciliationDelta, .expectedPaycheckNet:
            return .payPeriod
        case .observedPaidTips, .proposedPaidTipsCorrection, .observedGross, .observedNet, .observedTaxes:
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
        case .tipShareIn:
            return "none (nil tip share counts as 0)"
        case .observedPaidTips:
            return "nil until a paycheck is recorded"
        case .proposedPaidTipsCorrection:
            return "nil when no correction is inferred"
        case .reconciliationDelta:
            return "never added to income; absent components produce no delta"
        case .hourlyRate:
            return "nil without coverage; uncovered shifts excluded from both sides; carries N of M"
        case .observedGross, .observedNet, .observedTaxes:
            return "nil until a paycheck with this field is recorded"
        case .expectedPaycheckNet:
            return ".unavailable when the gross is unavailable or fewer than 2 stubs qualify; carries the gross figure's Completeness"
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
        case .tipShareIn:
            return ["Tip share received"]
        case .regularWages:
            return ["Wages"]
        case .overtimeWages:
            return ["Overtime"]
        case .expectedPaycheckTipsLine:
            return ["Your check's tips line"]
        case .expectedPaycheckGross:
            return ["Expected", "On your check, before tax"]
        case .observedPaidTips:
            return ["Paid"]
        case .proposedPaidTipsCorrection:
            return ["Looks like $X (accept?)"]
        case .reconciliationDelta:
            return ["checked"]
        case .hourlyRate:
            return ["Averaging $X/hr · N of M shifts"]
        case .observedGross:
            return ["Gross Income"]
        case .observedNet:
            return ["Net Income"]
        case .observedTaxes:
            return ["Taxes"]
        case .expectedPaycheckNet:
            return ["After tax, about"]
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
