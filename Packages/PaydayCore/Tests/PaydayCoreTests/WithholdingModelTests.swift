import Foundation
import Testing
@testable import PaydayCore

/// Seven SYNTHETIC biweekly stubs (cents). Generated on the line
/// `net = 0.76 × gross + 15000` with a few hundred cents of noise, so the
/// effective rate climbs with gross the way bracketed withholding does
/// (13.7% at the smallest check, 18.4% at the largest). No row is a real
/// stub; this repository is public and never carries a person's payroll.
private let rows: [(String, Int, Int)] = [
    ("2026-05-10", 149_500, 129_040),
    ("2026-05-24", 231_000, 190_180),
    ("2026-06-07", 182_500, 153_850),
    ("2026-06-21", 264_000, 215_380),
    ("2026-07-05", 171_000, 145_050),
    ("2026-07-19", 199_000, 166_030),
    ("2026-08-02", 213_500, 177_570),
]

private func date(_ s: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let p = s.split(separator: "-").map { Int($0)! }
    return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
}

private let fixture: [StubObservation] = rows.map {
    StubObservation(periodEnd: date($0.0), grossCents: $0.1, netCents: $0.2)
}

@Suite("WithholdingModel")
struct WithholdingModelTests {
    @Test("seven stubs fit the line they were generated on")
    func line() throws {
        let model = try #require(WithholdingModel.fit(fixture))
        guard case .line(let slope, let intercept) = model.kind else {
            Issue.record("expected .line, got \(model.kind)")
            return
        }
        #expect(abs(slope - 0.7543) < 0.001)
        #expect(abs(intercept - 16_161) < 100)
        #expect(model.stubCount == 7)
        #expect(model.grossRangeCents == 149_500...264_000)
    }

    @Test("chronological typical miss is the median of the backtest")
    func typicalMiss() throws {
        let model = try #require(WithholdingModel.fit(fixture))
        let miss = try #require(model.typicalMissCents)
        // Chronological misses on the fixture: 37, 432, 132, 218, 429 → lower-middle median 218.
        #expect(abs(miss - 218) <= 100)
    }

    @Test("leave-one-out worst miss stays under 1300c")
    func leaveOneOut() throws {
        var worst = 0
        for i in fixture.indices {
            var rest = fixture
            let held = rest.remove(at: i)
            let model = try #require(WithholdingModel.fit(rest))
            worst = max(worst, abs(model.predictNetCents(grossCents: held.grossCents) - held.netCents))
        }
        #expect(worst <= 1_300) // measured 429 on the fixture
    }

    @Test("two stubs fall back to a ratio; one gives no model")
    func smallCounts() throws {
        let two = try #require(WithholdingModel.fit(Array(fixture.prefix(2))))
        guard case .ratio = two.kind else { Issue.record("expected .ratio"); return }
        #expect(two.typicalMissCents == nil)
        #expect(WithholdingModel.fit(Array(fixture.prefix(1))) == nil)
        #expect(WithholdingModel.fit([]) == nil)
    }

    @Test("equal gross everywhere falls back to a ratio")
    func zeroVariance() throws {
        let stubs = (0..<4).map {
            StubObservation(periodEnd: date("2026-08-0\($0 + 1)"), grossCents: 200_000, netCents: 160_000 + $0 * 100)
        }
        let model = try #require(WithholdingModel.fit(stubs))
        guard case .ratio = model.kind else { Issue.record("expected .ratio"); return }
    }

    @Test("bad stubs are dropped")
    func filtering() {
        let bad = [
            StubObservation(periodEnd: date("2026-08-01"), grossCents: 0, netCents: 0),
            StubObservation(periodEnd: date("2026-08-02"), grossCents: 1_000, netCents: 2_000),
            fixture[0],
        ]
        #expect(WithholdingModel.fit(bad) == nil)
    }

    @Test("prediction clamps to 0...gross")
    func clamps() {
        let high = WithholdingModel(kind: .line(slope: 1.0, interceptCents: 50_000), stubCount: 3,
                                    grossRangeCents: 1...2, typicalMissCents: nil)
        #expect(high.predictNetCents(grossCents: 10_000) == 10_000)
        let low = WithholdingModel(kind: .line(slope: 0.5, interceptCents: -50_000), stubCount: 3,
                                   grossRangeCents: 1...2, typicalMissCents: nil)
        #expect(low.predictNetCents(grossCents: 10_000) == 0)
        #expect(low.predictNetCents(grossCents: 0) == 0)
    }

    @Test("extrapolation flags outside 0.8×min ... 1.2×max")
    func extrapolation() throws {
        let model = try #require(WithholdingModel.fit(fixture))
        #expect(model.isExtrapolating(grossCents: 110_000))
        #expect(model.isExtrapolating(grossCents: 350_000))
        #expect(!model.isExtrapolating(grossCents: 180_000))
    }

    @Test("input order does not matter")
    func orderIndependent() {
        let a = WithholdingModel.fit(fixture)
        let b = WithholdingModel.fit(fixture.reversed())
        let c = WithholdingModel.fit([fixture[3], fixture[0], fixture[6], fixture[2], fixture[5], fixture[1], fixture[4]])
        #expect(a == b)
        #expect(a == c)
    }

    @Test("window keeps only the last N")
    func window() throws {
        let model = try #require(WithholdingModel.fit(fixture, window: 4))
        #expect(model.stubCount == 4)
        #expect(model.grossRangeCents == 171_000...264_000)
        #expect(model == WithholdingModel.fit(Array(fixture.suffix(4))))
    }
}
