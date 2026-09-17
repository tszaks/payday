import Foundation
import Testing
@testable import PaydayCore

@Suite("MetricID registry")
struct MetricIDTests {
    @Test("The registry has exactly the 13 rows from the plan, by name")
    func exactCases() {
        let expected: Set<String> = [
            "earnedIncome", "nonWageEarnings", "voluntaryTips", "gratuityFees", "tipOut",
            "regularWages", "overtimeWages", "expectedPaycheckTipsLine", "expectedPaycheckGross",
            "observedPaidTips", "proposedPaidTipsCorrection", "reconciliationDelta", "hourlyRate",
        ]
        #expect(MetricID.allCases.count == 13)
        #expect(Set(MetricID.allCases.map(\.rawValue)) == expected)
    }

    @Test("Every metric has a definition and at least one allowed label", arguments: MetricID.allCases)
    func definitionsAndLabels(metric: MetricID) {
        #expect(!metric.definition.isEmpty)
        #expect(!metric.missingDataRule.isEmpty)
        #expect(!metric.allowedLabels.isEmpty)
        #expect(metric.allowedLabels.allSatisfy { !$0.isEmpty })
    }

    @Test("Registry labels match the plan table")
    func planLabels() {
        #expect(MetricID.earnedIncome.allowedLabels == ["Total", "Known so far", "Earned", "You kept"])
        #expect(MetricID.nonWageEarnings.allowedLabels == ["Tips", "Tips & gratuity"])
        // "As today's drawer rows": DashboardView + PeriodDetailView breakdown drawers.
        // Entry-field captions ("Cash", "Credit", "Gratuity") are input labels, not metric labels.
        #expect(MetricID.voluntaryTips.allowedLabels == ["Cash tips", "Credit tips", "Tips"])
        #expect(MetricID.gratuityFees.allowedLabels == ["Gratuity & fees"])
        #expect(MetricID.tipOut.allowedLabels == ["Tipped out"])
        #expect(MetricID.regularWages.allowedLabels == ["Wages · {hours}"])
        #expect(MetricID.overtimeWages.allowedLabels == ["Overtime · {hours}"])
        #expect(MetricID.expectedPaycheckTipsLine.allowedLabels == ["Your check's tips line"])
        #expect(MetricID.expectedPaycheckGross.allowedLabels == ["Expected"])
        #expect(MetricID.observedPaidTips.allowedLabels == ["Paid"])
        #expect(MetricID.proposedPaidTipsCorrection.allowedLabels == ["Looks like $X (accept?)"])
        #expect(MetricID.reconciliationDelta.allowedLabels == ["checked"])
        #expect(MetricID.hourlyRate.allowedLabels == ["Averaging $X/hr · N of M shifts"])
    }

    @Test("Every registry case has an explicit label assertion above")
    func everyCasePinned() {
        // Guard against a new case slipping in with only the generic non-empty check.
        let pinned: Set<MetricID> = [
            .earnedIncome, .nonWageEarnings, .voluntaryTips, .gratuityFees, .tipOut, .regularWages, .overtimeWages,
            .expectedPaycheckTipsLine, .expectedPaycheckGross, .observedPaidTips, .proposedPaidTipsCorrection,
            .reconciliationDelta, .hourlyRate,
        ]
        #expect(pinned == Set(MetricID.allCases))
    }

    @Test("Bases follow the plan table")
    func bases() {
        for m in [MetricID.earnedIncome, .nonWageEarnings, .voluntaryTips, .gratuityFees, .tipOut, .regularWages, .overtimeWages] {
            #expect(m.basis == .workDate)
        }
        for m in [MetricID.expectedPaycheckTipsLine, .expectedPaycheckGross, .reconciliationDelta] {
            #expect(m.basis == .payPeriod)
        }
        for m in [MetricID.observedPaidTips, .proposedPaidTipsCorrection] {
            #expect(m.basis == .payDate)
        }
        #expect(MetricID.hourlyRate.basis == .queryRange)
    }

    @Test("Raw values round-trip through Codable")
    func codable() throws {
        let data = try JSONEncoder().encode(MetricID.allCases)
        #expect(try JSONDecoder().decode([MetricID].self, from: data) == MetricID.allCases)
    }
}
