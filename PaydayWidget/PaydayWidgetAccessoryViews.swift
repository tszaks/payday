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

    var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.hasSchedule {
                VStack(spacing: 0) {
                    Text("TIPS")
                        .font(.system(size: 8, weight: .semibold))
                    Text(Money.wholeDollarString(fromCents: entry.periodTotalCents))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                }
            } else {
                Image(systemName: "banknote")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This period")
                .font(.system(size: 12, weight: .semibold))
            if entry.hasSchedule {
                Text(Money.string(fromCents: entry.periodTotalCents))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(entry.paceDeltaCents.map(RevealCopy.paceLine) ?? daysRemainingText)
                    .font(.system(size: 11))
                    .lineLimit(1)
            } else {
                Text("Set up Payday to see your total")
                    .font(.system(size: 11))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    var inlineView: some View {
        Group {
            if entry.hasSchedule {
                Text("Tips \(Money.wholeDollarString(fromCents: entry.periodTotalCents)) · \(daysRemainingText)")
            } else {
                Text("Set up Payday")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}
