import Foundation

/// One past pay stub's gross and net, the only two numbers the withholding
/// model learns from.
public struct StubObservation: Hashable, Sendable {
    /// Ordering key only. No date arithmetic is done on it.
    public let periodEnd: Date
    public let grossCents: Int
    public let netCents: Int

    public init(periodEnd: Date, grossCents: Int, netCents: Int) {
        self.periodEnd = periodEnd
        self.grossCents = grossCents
        self.netCents = netCents
    }
}

/// Predicts a check's net (after tax) from its gross (before tax), learned
/// from the person's own past stubs. `MetricID.expectedPaycheckNet`.
///
/// There are no tax tables here, on purpose: the stubs are the model.
/// Withholding is not a flat share of gross (federal runs in brackets, so the
/// effective rate climbs with gross), so with 3+ stubs the model is a
/// least-squares line `net = slope × gross + intercept`. Backtested on a
/// real seven-stub history before it was written: predicting each stub from
/// only the stubs before it, the line's average miss was about a fifth of a
/// flat median ratio's. The figures themselves stay out of this public
/// repository; the test fixture is synthetic.
public struct WithholdingModel: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// net = slope × gross + intercept.
        case line(slope: Double, interceptCents: Double)
        /// net = netOverGross × gross. Used with exactly 2 stubs, or when every
        /// gross is the same and a line has no slope to learn.
        case ratio(netOverGross: Double)
    }

    public let kind: Kind
    /// How many stubs the model was fitted on (after filtering and window).
    public let stubCount: Int
    /// Smallest ... largest gross the model was fitted on.
    public let grossRangeCents: ClosedRange<Int>
    /// Median absolute miss when each stub is predicted only from the stubs
    /// before it. For an even count this is the lower-middle value. Nil with
    /// fewer than 2 backtest points.
    public let typicalMissCents: Int?

    public init(kind: Kind, stubCount: Int, grossRangeCents: ClosedRange<Int>, typicalMissCents: Int?) {
        self.kind = kind
        self.stubCount = stubCount
        self.grossRangeCents = grossRangeCents
        self.typicalMissCents = typicalMissCents
    }

    /// Fits on the last `window` usable stubs. Nil with fewer than 2.
    ///
    /// Usable: gross > 0, net > 0, net <= gross. Sorted by periodEnd, then
    /// gross, then net, so the result does not depend on input order.
    public static func fit(_ stubs: [StubObservation], window: Int = 8) -> WithholdingModel? {
        let usable = stubs
            .filter { $0.grossCents > 0 && $0.netCents > 0 && $0.netCents <= $0.grossCents }
            .sorted {
                if $0.periodEnd != $1.periodEnd { return $0.periodEnd < $1.periodEnd }
                if $0.grossCents != $1.grossCents { return $0.grossCents < $1.grossCents }
                return $0.netCents < $1.netCents
            }
        let kept = Array(usable.suffix(max(window, 0)))
        guard let kind = fitKind(kept) else { return nil }

        var misses: [Int] = []
        if kept.count > 2 {
            for i in 2..<kept.count {
                guard let prior = fitKind(Array(kept[0..<i])) else { continue }
                let predicted = predict(prior, grossCents: kept[i].grossCents)
                misses.append(abs(predicted - kept[i].netCents))
            }
        }
        let typical: Int?
        if misses.count >= 2 {
            let sorted = misses.sorted()
            typical = sorted[(sorted.count - 1) / 2]
        } else {
            typical = nil
        }

        let grosses = kept.map(\.grossCents)
        return WithholdingModel(
            kind: kind,
            stubCount: kept.count,
            grossRangeCents: grosses.min()!...grosses.max()!,
            typicalMissCents: typical
        )
    }

    /// Predicted net, half-up to whole cents, clamped to 0...grossCents.
    public func predictNetCents(grossCents: Int) -> Int {
        Self.predict(kind, grossCents: grossCents)
    }

    /// True when `grossCents` is outside 0.8 × min ... 1.2 × max of the gross
    /// the model has seen.
    public func isExtrapolating(grossCents: Int) -> Bool {
        let low = Double(grossRangeCents.lowerBound) * 0.8
        let high = Double(grossRangeCents.upperBound) * 1.2
        let g = Double(grossCents)
        return g < low || g > high
    }

    // MARK: - Private

    private static func fitKind(_ stubs: [StubObservation]) -> Kind? {
        guard stubs.count >= 2 else { return nil }
        let xs = stubs.map { Double($0.grossCents) }
        let ys = stubs.map { Double($0.netCents) }
        let ratio = Kind.ratio(netOverGross: zip(xs, ys).map { $1 / $0 }.reduce(0, +) / Double(stubs.count))
        guard stubs.count >= 3 else { return ratio }
        let n = Double(stubs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
        }
        guard sxx > 0 else { return ratio }
        let slope = sxy / sxx
        return .line(slope: slope, interceptCents: meanY - slope * meanX)
    }

    private static func predict(_ kind: Kind, grossCents: Int) -> Int {
        guard grossCents > 0 else { return 0 }
        let raw: Double
        switch kind {
        case .line(let slope, let intercept): raw = slope * Double(grossCents) + intercept
        case .ratio(let r): raw = r * Double(grossCents)
        }
        let rounded = Int((raw + 0.5).rounded(.down))
        return min(max(rounded, 0), grossCents)
    }
}
