import Testing
import Foundation
@testable import Payday

private func stub(
    tips: Int? = nil,
    regular: Int? = nil,
    overtime: Int? = nil,
    gross: Int? = nil,
    taxes: Int? = nil,
    net: Int? = nil
) -> PaycheckAudit.Stub {
    PaycheckAudit.Stub(tipsCents: tips, regularWagesCents: regular, overtimeWagesCents: overtime, grossCents: gross, taxesCents: taxes, netCents: net)
}

private func findings(
    _ stub: PaycheckAudit.Stub,
    loggedCreditTipsCents: Int? = nil,
    computedWages: PeriodIncome.Wages? = nil,
    computedOvertimeHours: Double? = nil
) -> [PaycheckAudit.Finding] {
    PaycheckAudit.run(stub: stub, loggedCreditTipsCents: loggedCreditTipsCents, computedWages: computedWages, computedOvertimeHours: computedOvertimeHours)
}

private func finding(_ findings: [PaycheckAudit.Finding], id: String) -> PaycheckAudit.Finding? {
    findings.first { $0.id == id }
}

@Suite("PaycheckAudit gross-math")
struct PaycheckAuditGrossMathTests {
    @Test("reconciles when tips plus wages exactly match the gross")
    func exactMatchReconciles() {
        let result = findings(stub(tips: 5000, gross: 5000))
        #expect(finding(result, id: "gross-math") == PaycheckAudit.Finding(id: "gross-math", severity: .reconciles, message: "Tips and wages add up to the gross."))
    }

    @Test("wages are folded into earned when present")
    func wagesFoldIntoEarned() {
        let result = findings(stub(tips: 3000, regular: 1000, overtime: 500, gross: 4500))
        #expect(finding(result, id: "gross-math")?.severity == .reconciles)
    }

    @Test("within the 5-cent tolerance still reconciles")
    func withinToleranceReconciles() {
        let result = findings(stub(tips: 5000, gross: 5005))
        #expect(finding(result, id: "gross-math")?.severity == .reconciles)
    }

    @Test("one cent past the tolerance is a discrepancy")
    func pastToleranceIsDiscrepancy() {
        let result = findings(stub(tips: 5000, gross: 5006))
        #expect(finding(result, id: "gross-math")?.severity == .discrepancy)
    }

    @Test("discrepancy copy is exact, whole dollars")
    func discrepancyExactCopyWholeDollars() {
        let result = findings(stub(tips: 5000, gross: 6000))
        #expect(finding(result, id: "gross-math") == PaycheckAudit.Finding(
            id: "gross-math",
            severity: .discrepancy,
            message: "Tips and wages come to $50 - the stub's gross is $60. $10 unaccounted."
        ))
    }

    @Test("discrepancy copy falls back to cents when the amount isn't an even dollar")
    func discrepancyExactCopyWithCents() {
        let result = findings(stub(tips: 1005, gross: 2000))
        #expect(finding(result, id: "gross-math") == PaycheckAudit.Finding(
            id: "gross-math",
            severity: .discrepancy,
            message: "Tips and wages come to $10.05 - the stub's gross is $20. $9.95 unaccounted."
        ))
    }

    @Test("absent when tips is missing")
    func absentWhenTipsMissing() {
        let result = findings(stub(gross: 5000))
        #expect(finding(result, id: "gross-math") == nil)
    }

    @Test("absent when gross is missing")
    func absentWhenGrossMissing() {
        let result = findings(stub(tips: 5000))
        #expect(finding(result, id: "gross-math") == nil)
    }
}

@Suite("PaycheckAudit net-math")
struct PaycheckAuditNetMathTests {
    @Test("reconciles when net exactly matches gross minus taxes")
    func exactMatchReconciles() {
        let result = findings(stub(gross: 10000, taxes: 2000, net: 8000))
        #expect(finding(result, id: "net-math") == PaycheckAudit.Finding(id: "net-math", severity: .reconciles, message: "Gross minus taxes matches the net."))
    }

    @Test("within the 5-cent tolerance still reconciles")
    func withinToleranceReconciles() {
        let result = findings(stub(gross: 10000, taxes: 2000, net: 8005))
        #expect(finding(result, id: "net-math")?.severity == .reconciles)
    }

    @Test("net below expected by more than tolerance is a note, exact copy")
    func netBelowExpectedIsNote() {
        let result = findings(stub(gross: 10000, taxes: 2000, net: 7000))
        #expect(finding(result, id: "net-math") == PaycheckAudit.Finding(
            id: "net-math",
            severity: .note,
            message: "Gross minus taxes leaves $80; net is $70. $10 in other deductions or withholdings."
        ))
    }

    @Test("net above expected by more than tolerance is a discrepancy, exact copy")
    func netAboveExpectedIsDiscrepancy() {
        let result = findings(stub(gross: 10000, taxes: 2000, net: 9000))
        #expect(finding(result, id: "net-math") == PaycheckAudit.Finding(
            id: "net-math",
            severity: .discrepancy,
            message: "Net is higher than gross minus taxes - one of these numbers is off."
        ))
    }

    @Test("absent when any of gross, taxes, net is missing")
    func absentWhenAnyInputMissing() {
        #expect(finding(findings(stub(taxes: 2000, net: 8000)), id: "net-math") == nil)
        #expect(finding(findings(stub(gross: 10000, net: 8000)), id: "net-math") == nil)
        #expect(finding(findings(stub(gross: 10000, taxes: 2000)), id: "net-math") == nil)
    }
}

@Suite("PaycheckAudit tips-vs-logged")
struct PaycheckAuditTipsVsLoggedTests {
    @Test("reconciles when the stub's tips match what was logged")
    func exactMatchReconciles() {
        let result = findings(stub(tips: 5000), loggedCreditTipsCents: 5000)
        #expect(finding(result, id: "tips-vs-logged") == PaycheckAudit.Finding(id: "tips-vs-logged", severity: .reconciles, message: "The tips line matches what you logged."))
    }

    @Test("within the 5-cent tolerance still reconciles")
    func withinToleranceReconciles() {
        let result = findings(stub(tips: 5005), loggedCreditTipsCents: 5000)
        #expect(finding(result, id: "tips-vs-logged")?.severity == .reconciles)
    }

    @Test("stub short of logged tips reads short, exact copy")
    func stubShortReadsShort() {
        let result = findings(stub(tips: 4000), loggedCreditTipsCents: 5000)
        #expect(finding(result, id: "tips-vs-logged") == PaycheckAudit.Finding(
            id: "tips-vs-logged",
            severity: .discrepancy,
            message: "You logged $50 in credit tips; the stub pays $40. $10 short."
        ))
    }

    @Test("stub over logged tips reads over, exact copy")
    func stubOverReadsOver() {
        let result = findings(stub(tips: 6000), loggedCreditTipsCents: 5000)
        #expect(finding(result, id: "tips-vs-logged") == PaycheckAudit.Finding(
            id: "tips-vs-logged",
            severity: .discrepancy,
            message: "You logged $50 in credit tips; the stub pays $60. $10 over."
        ))
    }

    @Test("absent when tips or logged credit tips is missing")
    func absentWhenInputMissing() {
        #expect(finding(findings(stub(), loggedCreditTipsCents: 5000), id: "tips-vs-logged") == nil)
        #expect(finding(findings(stub(tips: 5000), loggedCreditTipsCents: nil), id: "tips-vs-logged") == nil)
    }
}

@Suite("PaycheckAudit wages-vs-computed")
struct PaycheckAuditWagesVsComputedTests {
    private let computed = PeriodIncome.Wages(regularCents: 40000, overtimeCents: 5000, hours: 45, overtimeHours: 5)

    @Test("reconciles when stub wages exactly match the computed total")
    func exactMatchReconciles() {
        let result = findings(stub(regular: 45000), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed") == PaycheckAudit.Finding(id: "wages-vs-computed", severity: .reconciles, message: "Wages match Payday's math from your punches."))
    }

    @Test("within the $1 tolerance still reconciles")
    func withinToleranceReconciles() {
        let result = findings(stub(regular: 45100), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed")?.severity == .reconciles)
    }

    @Test("one cent past the $1 tolerance is no longer a reconcile")
    func oneCentPastToleranceIsNotReconciled() {
        let result = findings(stub(regular: 45101), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed")?.severity != .reconciles)
    }

    @Test("one cent past the $1 tolerance, stub under computed, is a discrepancy with exact copy")
    func underComputedIsDiscrepancy() {
        let result = findings(stub(regular: 30000), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed") == PaycheckAudit.Finding(
            id: "wages-vs-computed",
            severity: .discrepancy,
            message: "From your punches Payday computes $400 regular and $50 overtime - the stub pays $300. You may be owed $150."
        ))
    }

    @Test("stub over computed by more than $1 is a note with exact copy")
    func overComputedIsNote() {
        let result = findings(stub(regular: 50000), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed") == PaycheckAudit.Finding(
            id: "wages-vs-computed",
            severity: .note,
            message: "The stub pays $50 more in wages than Payday computes from your punches."
        ))
    }

    @Test("overtime alone is enough to trigger the check")
    func overtimeAloneTriggers() {
        let result = findings(stub(overtime: 5000), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed")?.severity == .discrepancy)
    }

    @Test("absent when neither regular nor overtime is entered")
    func absentWhenNoWagesEntered() {
        let result = findings(stub(tips: 5000), computedWages: computed)
        #expect(finding(result, id: "wages-vs-computed") == nil)
    }

    @Test("absent when there's no computed wages to compare against")
    func absentWhenComputedWagesMissing() {
        let result = findings(stub(regular: 45000), computedWages: nil)
        #expect(finding(result, id: "wages-vs-computed") == nil)
    }
}

@Suite("PaycheckAudit overtime-missing")
struct PaycheckAuditOvertimeMissingTests {
    @Test("discrepancy when punches show overtime the stub doesn't, exact copy")
    func firesWithExactCopy() {
        let result = findings(stub(tips: 5000), computedOvertimeHours: 5.0)
        #expect(finding(result, id: "overtime-missing") == PaycheckAudit.Finding(
            id: "overtime-missing",
            severity: .discrepancy,
            message: "Your punches add up to 5h overtime hours this period; the stub shows no overtime pay."
        ))
    }

    @Test("fires when overtime is explicitly zero, not just nil")
    func firesWhenOvertimeIsZero() {
        let result = findings(stub(tips: 5000, overtime: 0), computedOvertimeHours: 5.0)
        #expect(finding(result, id: "overtime-missing")?.severity == .discrepancy)
    }

    @Test("absent when no overtime hours were computed")
    func absentWhenNoComputedOvertime() {
        #expect(finding(findings(stub(tips: 5000), computedOvertimeHours: nil), id: "overtime-missing") == nil)
        #expect(finding(findings(stub(tips: 5000), computedOvertimeHours: 0), id: "overtime-missing") == nil)
    }

    @Test("absent when the stub already has overtime pay entered")
    func absentWhenOvertimeEntered() {
        let result = findings(stub(tips: 5000, overtime: 7500), computedOvertimeHours: 5.0)
        #expect(finding(result, id: "overtime-missing") == nil)
    }

    @Test("absent when no other stub field has been entered yet")
    func absentWhenNothingElseEntered() {
        let result = findings(stub(), computedOvertimeHours: 5.0)
        #expect(finding(result, id: "overtime-missing") == nil)
    }
}

@Suite("PaycheckAudit ordering and silence")
struct PaycheckAuditOrderingTests {
    @Test("findings come back in gross-math, net-math, tips-vs-logged, wages-vs-computed, overtime-missing order")
    func findingsAreOrdered() {
        let computed = PeriodIncome.Wages(regularCents: 25000, overtimeCents: 0, hours: 45, overtimeHours: 5)
        let result = findings(
            stub(tips: 10000, regular: 20000, gross: 40000, taxes: 5000, net: 30000),
            loggedCreditTipsCents: 9000,
            computedWages: computed,
            computedOvertimeHours: computed.overtimeHours
        )
        #expect(result.map(\.id) == ["gross-math", "net-math", "tips-vs-logged", "wages-vs-computed", "overtime-missing"])
    }

    @Test("a fully empty stub produces no findings at all")
    func emptyStubIsSilent() {
        #expect(findings(stub()).isEmpty)
    }
}

@Suite("PaycheckOCR")
struct PaycheckOCRTests {
    @Test("maps common pay-stub labels and adds tax lines")
    func mapsCommonLabels() {
        let parsed = PaycheckOCR.parse(lines: [
            "Card Tips $618.24",
            "Regular Pay $1,234.56",
            "Overtime Pay $123.45",
            "Gross Pay $1,976.25",
            "Federal Income Tax $200.00",
            "State Tax $50.00",
            "Social Security $120.00",
            "Medicare $28.00",
            "Net Pay $1,578.25"
        ])

        #expect(parsed.tipsCents == 61824)
        #expect(parsed.regularWagesCents == 123456)
        #expect(parsed.overtimeWagesCents == 12345)
        #expect(parsed.grossPayCents == 197625)
        #expect(parsed.taxesCents == 39800)
        #expect(parsed.netPayCents == 157825)
        #expect(parsed.filledFieldCount == 6)
    }

    @Test("prefers the printed total taxes line over its breakdown")
    func prefersTotalTaxes() {
        let parsed = PaycheckOCR.parse(lines: [
            "Federal Tax $200.00",
            "State Tax $50.00",
            "Total Taxes $275.00"
        ])

        #expect(parsed.taxesCents == 27500)
    }

    @Test("uses the current amount before the YTD amount")
    func usesCurrentAmount() {
        let parsed = PaycheckOCR.parse(lines: [
            "Gross Pay $1,976.25 $12,500.00 YTD",
            "Net Pay $1,578.25 $10,000.00 YTD"
        ])

        #expect(parsed.grossPayCents == 197625)
        #expect(parsed.netPayCents == 157825)
    }

    @Test("does not mistake tip-out for tips earned")
    func excludesTipOut() {
        let parsed = PaycheckOCR.parse(lines: [
            "Tip Out $100.00",
            "Credit Tips $618.24"
        ])

        #expect(parsed.tipsCents == 61824)
    }
}
