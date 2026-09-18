import SwiftUI
import WidgetKit

// Lock Screen and StandBy accessory families (circular, rectangular, inline).
// Kept out of PaydayWidget.swift and out of the design-lint's font-token
// check on purpose: the system renders these in its own monochrome tint,
// ignoring any PaydayColor set here, and Apple's guidance is plain system
// fonts, not the app's own SF Pro Rounded brand weights — matching other
// Lock Screen widgets is more correct here than matching Payday's own type
// scale. See scripts/design-lint.sh for the matching exclude.
extension PaydayWidgetEntryView {
    var daysRemainingText: String {
        entry.daysRemaining == 0 ? "Last day" : "\(entry.daysRemaining) day\(entry.daysRemaining == 1 ? "" : "s") left"
    }

    // widgetURL on all three: accessory families can't host an interactive
    // button (the system renders these itself), so a tap is only ever
    // reachable via this URL — payday://log, opened by PaydayApp's
    // onOpenURL, straight into the log sheet. The home-screen widget above
    // is untouched: its own interactive "+" button already covers this.
    private static let logURL = URL(string: "payday://log")

    /// The engine's figure for this entry, or nil when there is nothing to
    /// show yet.
    ///
    /// `.setup` and `.unavailable` are DIFFERENT states and must read
    /// differently: setup means "finish setting up", unavailable means
    /// "Payday could not read your shifts". Collapsing them would tell a user
    /// with a full history that they had not set the app up.
    private var figure: EarningsFigure? {
        if case .figure(let figure) = entry.content { return figure }
        return nil
    }

    /// The cents, only when the engine actually answered.
    private var cents: Int? {
        guard let figure, case .cents(let cents) = figure.amount else { return nil }
        return cents
    }

    var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let cents, let figure {
                VStack(spacing: 0) {
                    // THE ENGINE'S LABEL, uppercased for this face rather
                    // than hardcoded. It said "TIPS" over a WAGE-INCLUSIVE
                    // number, which is the mislabel the audit named: the face
                    // was telling the user their tips were larger than they
                    // were. Now it reads "TOTAL", or "KNOWN SO FAR" when a
                    // shift is unpriced, because the figure carries its own
                    // honest noun.
                    Text(figure.label.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                    Text(Money.wholeDollarString(fromCents: cents))
                        .privacySensitive()
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            } else {
                // Setup and unavailable both fall here, and neither renders a
                // currency string. A glyph is the honest answer for a face
                // this small.
                Image(systemName: "banknote")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(Self.logURL)
    }

    var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(figure.map { "This period · \($0.label)" } ?? "This period")
                .font(.system(size: 12, weight: .semibold))
            if let cents {
                Text(Money.string(fromCents: cents))
                        .privacySensitive()
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(entry.paceDeltaCents.map { Money.directionalDeltaString(fromCents: $0) } ?? daysRemainingText)
                        .privacySensitive()
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(entry.paceDeltaCents.map { RevealCopy.paceLine(deltaCents: $0, periodCount: entry.pacePeriodCount) } ?? daysRemainingText)
            } else if figure != nil {
                // The engine could not answer. Never "$0.00" -- a Lock Screen
                // zero on a store that failed to open is the same lie as the
                // app showing it, on a surface the user cannot refresh.
                Text("Couldn't load")
                    .font(.system(size: 11))
            } else {
                Text("Set up Payday to see your total")
                    .font(.system(size: 11))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(Self.logURL)
    }

    var inlineView: some View {
        Group {
            if let cents, let figure {
                // "Tips" was wrong here too, over the same wage-inclusive
                // number. The label is the engine's.
                Text("\(figure.label) \(Money.wholeDollarString(fromCents: cents)) · \(daysRemainingText)")
                        .privacySensitive()
            } else if figure != nil {
                Text("Payday couldn't load your shifts")
            } else {
                Text("Set up Payday")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(Self.logURL)
    }
}
