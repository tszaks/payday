import Testing
import Foundation
@testable import Payday

private func stub(
    tips: Int? = nil,
    regular: Int? = nil,
    overtime: Int? = nil,
    gratuity: Int? = nil,
    gross: Int? = nil,
    taxes: Int? = nil,
    net: Int? = nil
) -> PaycheckAudit.Stub {
    PaycheckAudit.Stub(tipsCents: tips, regularWagesCents: regular, overtimeWagesCents: overtime, gratuityCents: gratuity, grossCents: gross, taxesCents: taxes, netCents: net)
}

private func findings(
    _ stub: PaycheckAudit.Stub,
    loggedCreditTipsCents: Int? = nil,
    loggedGratuityCents: Int? = nil,
    computedWages: PeriodIncome.Wages? = nil,
    computedOvertimeHours: Double? = nil
) -> [PaycheckAudit.Finding] {
    PaycheckAudit.run(
        stub: stub,
        loggedCreditTipsCents: loggedCreditTipsCents,
        loggedGratuityCents: loggedGratuityCents,
        computedWages: computedWages,
        computedOvertimeHours: computedOvertimeHours
    )
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

    @Test("gratuity is included in gross reconciliation")
    func gratuityIsIncluded() {
        let result = findings(stub(tips: 232493, regular: 20699, gratuity: 15420, gross: 268612))
        #expect(finding(result, id: "gross-math") == PaycheckAudit.Finding(
            id: "gross-math",
            severity: .reconciles,
            message: "Tips, wages, and gratuity add up to the gross."
        ))
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
        #expect(finding(result, id: "tips-vs-logged") == PaycheckAudit.Finding(id: "tips-vs-logged", severity: .reconciles, message: "Tips match what you logged."))
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
            message: "You logged $50 in credit tips; the stub pays $40 in tips. $10 short."
        ))
    }

    @Test("stub over logged tips reads over, exact copy")
    func stubOverReadsOver() {
        let result = findings(stub(tips: 6000), loggedCreditTipsCents: 5000)
        #expect(finding(result, id: "tips-vs-logged") == PaycheckAudit.Finding(
            id: "tips-vs-logged",
            severity: .discrepancy,
            message: "You logged $50 in credit tips; the stub pays $60 in tips. $10 over."
        ))
    }

    @Test("separate gratuity cannot hide a credit-tip shortage")
    func gratuityDoesNotOffsetTipShortage() {
        let result = findings(
            stub(tips: 191_120, gratuity: 17_695),
            loggedCreditTipsCents: 207_957,
            loggedGratuityCents: 17_695
        )
        #expect(finding(result, id: "tips-vs-logged") == PaycheckAudit.Finding(
            id: "tips-vs-logged",
            severity: .discrepancy,
            message: "You logged $2,079.57 in credit tips; the stub pays $1,911.20 in tips. $168.37 short."
        ))
        #expect(finding(result, id: "gratuity-vs-logged")?.severity == .reconciles)
    }

    @Test("absent when tips or logged credit tips is missing")
    func absentWhenInputMissing() {
        #expect(finding(findings(stub(), loggedCreditTipsCents: 5000), id: "tips-vs-logged") == nil)
        #expect(finding(findings(stub(tips: 5000), loggedCreditTipsCents: nil), id: "tips-vs-logged") == nil)
    }
}

@Suite("PaycheckAudit gratuity-vs-logged")
struct PaycheckAuditGratuityVsLoggedTests {
    @Test("reconciles when the separate gratuity line matches")
    func exactMatchReconciles() {
        let result = findings(stub(gratuity: 17_695), loggedGratuityCents: 17_695)
        #expect(finding(result, id: "gratuity-vs-logged") == PaycheckAudit.Finding(
            id: "gratuity-vs-logged",
            severity: .reconciles,
            message: "Gratuity matches what you logged."
        ))
    }

    @Test("a gratuity shortage is reported independently")
    func shortReadsShort() {
        let result = findings(stub(gratuity: 15_000), loggedGratuityCents: 17_695)
        #expect(finding(result, id: "gratuity-vs-logged") == PaycheckAudit.Finding(
            id: "gratuity-vs-logged",
            severity: .discrepancy,
            message: "You logged $176.95 in gratuity and fees; the stub pays $150 in gratuity. $26.95 short."
        ))
    }

    @Test("logged gratuity with no entered stub line is a note")
    func missingStubLineIsNote() {
        let result = findings(stub(tips: 1), loggedGratuityCents: 4_050)
        #expect(finding(result, id: "gratuity-vs-logged") == PaycheckAudit.Finding(
            id: "gratuity-vs-logged",
            severity: .note,
            message: "You logged $40.50 in gratuity and fees; no gratuity line was entered from the stub."
        ))
    }

    @Test("silent when no gratuity was logged")
    func absentWhenLoggedInputMissing() {
        #expect(finding(findings(stub(gratuity: 4_050)), id: "gratuity-vs-logged") == nil)
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
    @Test("findings come back in gross, net, tips, gratuity, wages, overtime order")
    func findingsAreOrdered() {
        let computed = PeriodIncome.Wages(regularCents: 25000, overtimeCents: 0, hours: 45, overtimeHours: 5)
        let result = findings(
            stub(tips: 10000, regular: 20000, gross: 40000, taxes: 5000, net: 30000),
            loggedCreditTipsCents: 9000,
            loggedGratuityCents: 1000,
            computedWages: computed,
            computedOvertimeHours: computed.overtimeHours
        )
        #expect(result.map(\.id) == ["gross-math", "net-math", "tips-vs-logged", "gratuity-vs-logged", "wages-vs-computed", "overtime-missing"])
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

    @Test("adds repeated weekly rows into one pay-period total")
    func addsRepeatedWeeklyRows() {
        let parsed = PaycheckOCR.parse(lines: [
            "REGULAR $108.96 $919.20 38.50",
            "REGULAR $98.03 $919.20 34.64",
            "OVERTIME $0.00 0.00",
            "Tips Owed $1,244.37 $8,013.46",
            "Tips Owed $1,080.56 $8,013.46",
            "Gratuity Owed - Credit Card & Other $96.80 $154.20",
            "Gratuity Owed - Credit Card & Other $57.40 $154.20",
            "Gross Earnings $2,686.12 $9,384.13",
            "Total Taxes $493.10 $1,634.78",
            "Net Pay $2,193.02 $7,749.35"
        ])

        #expect(parsed.regularWagesCents == 20699)
        #expect(parsed.overtimeWagesCents == 0)
        #expect(parsed.tipsCents == 232493)
        #expect(parsed.gratuityCents == 15420)
        #expect(parsed.grossPayCents == 268612)
        #expect(parsed.taxesCents == 49310)
        #expect(parsed.netPayCents == 219302)
        #expect(parsed.filledFieldCount == 7)
    }

    @Test("rebuilds split Vision table observations into visual rows")
    func rebuildsVisionRows() {
        let observations = [
            PaycheckOCR.RecognizedText(text: "Tips Owed", boundingBox: CGRect(x: 0.10, y: 0.70, width: 0.10, height: 0.01)),
            PaycheckOCR.RecognizedText(text: "$879.09", boundingBox: CGRect(x: 0.30, y: 0.699, width: 0.08, height: 0.01)),
            PaycheckOCR.RecognizedText(text: "$9,924.66", boundingBox: CGRect(x: 0.40, y: 0.699, width: 0.09, height: 0.01)),
            PaycheckOCR.RecognizedText(text: "Tips Owed", boundingBox: CGRect(x: 0.10, y: 0.68, width: 0.10, height: 0.01)),
            PaycheckOCR.RecognizedText(text: "$1,032.11", boundingBox: CGRect(x: 0.30, y: 0.679, width: 0.09, height: 0.01)),
            PaycheckOCR.RecognizedText(text: "$9,924.66", boundingBox: CGRect(x: 0.40, y: 0.679, width: 0.09, height: 0.01))
        ]

        let parsed = PaycheckOCR.parse(lines: PaycheckOCR.visualLines(from: observations))

        #expect(parsed.tipsCents == 191_120)
    }

    @Test("prefers a currency cell over hours and rate in a merged row")
    func prefersCurrencyCell() {
        let parsed = PaycheckOCR.parse(lines: ["REGULAR 29.15 $82.49 $1,114.89 2.83"])
        #expect(parsed.regularWagesCents == 8_249)
    }

    @Test("does not guess wages from an unmarked multi-number row")
    func rejectsAmbiguousUnmarkedWageRow() {
        let parsed = PaycheckOCR.parse(lines: ["REGULAR 29.15 82.49 1,114.89 2.83"])
        #expect(parsed.regularWagesCents == nil)
    }

    @Test("parses this Kooma paycheck's exact current-period rows")
    func parsesKoomaAugustPaycheck() {
        let parsed = PaycheckOCR.parse(lines: [
            "REGULAR $82.49 $1,114.89 29.15 2.83",
            "REGULAR $113.20 $1,114.89 40.00 2.83",
            "OVERTIME $4.23 $46.95 0.60 7.05",
            "Tips Owed $879.09 $9,924.66",
            "Tips Owed $1,032.11 $9,924.66",
            "Gratuity Owed - Credit Card & Other $128.65 $585.70",
            "Gratuity Owed - Credit Card & Other $48.30 $585.70",
            "Gross Earnings $2,288.07 $11,672.20",
            "Total Taxes $385.56 $2,020.34",
            "Net Pay $1,902.51 $9,651.86",
            "Amount Paid $1,902.51",
            "CHECK FACE $1902.51"
        ]).correctingSmallGrossMismatch()

        #expect(parsed.tipsCents == 191_120)
        #expect(parsed.regularWagesCents == 19_569)
        #expect(parsed.overtimeWagesCents == 423)
        #expect(parsed.gratuityCents == 17_695)
        #expect(parsed.grossPayCents == 228_807)
        #expect(parsed.taxesCents == 38_556)
        #expect(parsed.netPayCents == 190_251)
        #expect(parsed.filledFieldCount == 7)
    }

    @Test("repairs a small tips OCR error when gross proves the printed amount")
    func repairsSmallTipsErrorFromGross() {
        let parsed = PaycheckOCR.ParsedPaycheck(
            tipsCents: 191_102,
            regularWagesCents: 19_569,
            overtimeWagesCents: 423,
            gratuityCents: 17_695,
            grossPayCents: 228_807,
            taxesCents: 38_556,
            netPayCents: 190_251
        ).correctingSmallGrossMismatch()

        #expect(parsed.tipsCents == 191_120)
    }

    @Test("does not rewrite a large gross mismatch that may be another earning")
    func preservesLargeGrossMismatch() {
        let parsed = PaycheckOCR.ParsedPaycheck(
            tipsCents: 100_000,
            regularWagesCents: 20_000,
            overtimeWagesCents: nil,
            gratuityCents: nil,
            grossPayCents: 125_000,
            taxesCents: nil,
            netPayCents: nil
        ).correctingSmallGrossMismatch()

        #expect(parsed.tipsCents == 100_000)
    }

    @Test("does not infer a correction when an earnings category was not read")
    func doesNotCorrectIncompleteEarnings() {
        let parsed = PaycheckOCR.ParsedPaycheck(
            tipsCents: 191_102,
            regularWagesCents: 19_569,
            overtimeWagesCents: nil,
            gratuityCents: 17_695,
            grossPayCents: 228_807,
            taxesCents: nil,
            netPayCents: nil
        ).correctingSmallGrossMismatch()

        #expect(parsed.tipsCents == 191_102)
    }

    @Test("decodes AI totals as cents")
    func decodesAITotals() {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"tips\":2324.93,\"regular_wages\":206.99,\"overtime_wages\":0,\"gratuity\":154.20,\"gross_pay\":2686.12,\"taxes\":493.10,\"net_pay\":2193.02}"}]}]}"#.utf8)
        let parsed = try? PaycheckAIParser.parse(responseData: response)

        #expect(parsed?.tipsCents == 232493)
        #expect(parsed?.regularWagesCents == 20699)
        #expect(parsed?.gratuityCents == 15420)
        #expect(parsed?.grossPayCents == 268612)
        #expect(parsed?.taxesCents == 49310)
        #expect(parsed?.netPayCents == 219302)
    }

    @Test("AI returns evidence rows and Payday combines the two paycheck weeks")
    func combinesAIEvidenceRows() {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"earnings_rows\":[{\"category\":\"regular_wages\",\"label\":\"REGULAR\",\"current_amount\":82.49},{\"category\":\"regular_wages\",\"label\":\"REGULAR\",\"current_amount\":113.20},{\"category\":\"overtime_wages\",\"label\":\"OVERTIME\",\"current_amount\":4.23},{\"category\":\"tips\",\"label\":\"Tips Owed\",\"current_amount\":879.09},{\"category\":\"tips\",\"label\":\"Tips Owed\",\"current_amount\":1032.11},{\"category\":\"gratuity\",\"label\":\"Gratuity Owed - Credit Card & Other\",\"current_amount\":128.65},{\"category\":\"gratuity\",\"label\":\"Gratuity Owed - Credit Card & Other\",\"current_amount\":48.30}],\"gross_pay\":2288.07,\"taxes\":385.56,\"net_pay\":1902.51}"}]}]}"#.utf8)
        let parsed = try? PaycheckAIParser.parse(responseData: response)

        #expect(parsed?.tipsCents == 191_120)
        #expect(parsed?.regularWagesCents == 19_569)
        #expect(parsed?.overtimeWagesCents == 423)
        #expect(parsed?.gratuityCents == 17_695)
        #expect(parsed?.grossPayCents == 228_807)
        #expect(parsed?.taxesCents == 38_556)
        #expect(parsed?.netPayCents == 190_251)
    }
}
