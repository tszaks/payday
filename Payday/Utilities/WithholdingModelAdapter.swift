import Foundation
import PaydayCore

/// Turns recorded paychecks into the person's `WithholdingModel`.
///
/// Only records with both a gross and a net count: those are the two numbers
/// the model learns from. Everything else about the fit lives in PaydayCore.
enum WithholdingModelAdapter {
    static func observations(from paychecks: [PaycheckRecord]) -> [StubObservation] {
        paychecks.compactMap { record in
            guard let gross = record.grossPayCents, let net = record.netPayCents else { return nil }
            return StubObservation(periodEnd: record.periodEnd, grossCents: gross, netCents: net)
        }
    }

    static func model(from paychecks: [PaycheckRecord]) -> WithholdingModel? {
        WithholdingModel.fit(observations(from: paychecks))
    }
}
