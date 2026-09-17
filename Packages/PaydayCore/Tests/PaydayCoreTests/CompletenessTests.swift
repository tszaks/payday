import Testing
@testable import PaydayCore

@Suite("Completeness")
struct CompletenessTests {
    @Test("no shifts wins over everything, even with wages off")
    func noShifts() {
        let c = Completeness(totalShifts: 0, shiftsWithHours: 0, shiftsWageValued: 0, shiftsWageAssumed: 0, wageFeatureEnabled: false)
        #expect(c.state == .noShifts)
        #expect(Completeness.empty.state == .noShifts)
    }

    @Test("wages off with shifts present is .off regardless of counts")
    func off() {
        let c = Completeness(totalShifts: 3, shiftsWithHours: 3, shiftsWageValued: 3, shiftsWageAssumed: 0, wageFeatureEnabled: false)
        #expect(c.state == .off)
        let partialButOff = Completeness(totalShifts: 3, shiftsWithHours: 1, shiftsWageValued: 0, shiftsWageAssumed: 0, wageFeatureEnabled: false)
        #expect(partialButOff.state == .off)
    }

    @Test("every shift valued and none assumed is .complete")
    func complete() {
        let c = Completeness(totalShifts: 5, shiftsWithHours: 5, shiftsWageValued: 5, shiftsWageAssumed: 0, wageFeatureEnabled: true)
        #expect(c.state == .complete)
    }

    @Test("every shift valued but some assumed is .estimated")
    func estimated() {
        let c = Completeness(totalShifts: 5, shiftsWithHours: 5, shiftsWageValued: 5, shiftsWageAssumed: 2, wageFeatureEnabled: true)
        #expect(c.state == .estimated)
        let allAssumed = Completeness(totalShifts: 5, shiftsWithHours: 5, shiftsWageValued: 5, shiftsWageAssumed: 5, wageFeatureEnabled: true)
        #expect(allAssumed.state == .estimated)
    }

    @Test("missing hours only")
    func partialMissingHours() {
        let c = Completeness(totalShifts: 5, shiftsWithHours: 4, shiftsWageValued: 4, shiftsWageAssumed: 0, wageFeatureEnabled: true)
        #expect(c.state == .partial(missingHours: 1, missingRate: 0))
    }

    @Test("missing rate only")
    func partialMissingRate() {
        let c = Completeness(totalShifts: 2, shiftsWithHours: 2, shiftsWageValued: 0, shiftsWageAssumed: 0, wageFeatureEnabled: true)
        #expect(c.state == .partial(missingHours: 0, missingRate: 2))
    }

    @Test("missing hours and rate together")
    func partialBoth() {
        let c = Completeness(totalShifts: 6, shiftsWithHours: 4, shiftsWageValued: 1, shiftsWageAssumed: 1, wageFeatureEnabled: true)
        #expect(c.state == .partial(missingHours: 2, missingRate: 3))
    }

    @Test("H1 shape: one of two shifts has hours and no rate policy exists")
    func h1Shape() {
        let c = Completeness(totalShifts: 2, shiftsWithHours: 1, shiftsWageValued: 0, shiftsWageAssumed: 0, wageFeatureEnabled: true)
        #expect(c.state == .partial(missingHours: 1, missingRate: 1))
    }

    @Test("WageState round-trips through Codable")
    func codable() throws {
        let states: [WageState] = [.off, .complete, .estimated, .partial(missingHours: 2, missingRate: 3), .noShifts]
        for state in states {
            let data = try JSONEncoder().encode(state)
            #expect(try JSONDecoder().decode(WageState.self, from: data) == state)
        }
    }
}

import Foundation
