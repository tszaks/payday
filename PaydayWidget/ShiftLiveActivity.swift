import SwiftUI
import WidgetKit
import ActivityKit

/// Lock screen + Dynamic Island for the one active shift session — the same
/// "punches are literal" law extended to what's on screen while the shift
/// is still running: a live elapsed timer off the exact clock-in, nothing
/// rounded, nothing simulated.
struct ShiftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftSessionAttributes.self) { context in
            lockScreenView(startedAt: context.state.startedAt)
                .activityBackgroundTint(PaydayColor.background)
                .widgetURL(URL(string: "payday://shift"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ON SHIFT")
                            .font(PaydayFont.caption2)
                            .tracking(1)
                            .foregroundStyle(PaydayColor.primary)
                        Text(sinceCaption(startedAt: context.state.startedAt))
                            .font(PaydayFont.caption2)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: EndShiftIntent()) {
                        Text("End")
                            .font(PaydayFont.subheadline)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(PaydayColor.primary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(timerInterval: timerRange(startedAt: context.state.startedAt), countsDown: false)
                        .font(PaydayFont.displayCompact)
                        .monospacedDigit()
                        .foregroundStyle(PaydayColor.textPrimary)
                }
            } compactLeading: {
                // Apple's compact grammar (Timer: orange glyph + orange
                // countdown): identity glyph leading, metric in the same
                // accent trailing. Payday's glyph is its green dollar —
                // text-forward, unmistakable, and never confusable with
                // the system's green privacy dot the old 8pt circle
                // impersonated.
                Text("$")
                    .font(PaydayFont.displaySmall)
                    .foregroundStyle(PaydayColor.primary)
            } compactTrailing: {
                Text(timerInterval: timerRange(startedAt: context.state.startedAt), countsDown: false)
                    .font(PaydayFont.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.primary)
                    .frame(maxWidth: 60, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } minimal: {
                Text("$")
                    .font(PaydayFont.displaySmall)
                    .foregroundStyle(PaydayColor.primary)
            }
        }
    }

    /// Twelve hours out is far past any real shift — just a ceiling so
    /// Text(timerInterval:) has a bounded range to render against.
    private func timerRange(startedAt: Date) -> ClosedRange<Date> {
        startedAt...startedAt.addingTimeInterval(12 * 3600)
    }

    private func sinceCaption(startedAt: Date) -> String {
        "since \(startedAt.formatted(.dateTime.hour().minute()))"
    }

    /// Composed like Apple's own Timer activity: identity whispered in a
    /// header row (the same 8pt green dot + tracked kicker as the app's
    /// hero band — one live language across every surface), the elapsed
    /// time as the undisputed hero underneath, and one quiet tinted action.
    /// The since-caption balances the header's trailing edge so the canvas
    /// has no dead middle.
    private func lockScreenView(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.p8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: PaydaySpacing.p8) {
                    Circle()
                        .fill(PaydayColor.primary)
                        .frame(width: 8, height: 8)
                    Text("ON SHIFT")
                        .font(PaydayFont.caption2)
                        .tracking(1.2)
                        .foregroundStyle(PaydayColor.primary)
                }
                Spacer()
                Text(sinceCaption(startedAt: startedAt))
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
            }

            HStack(alignment: .center, spacing: PaydaySpacing.p12) {
                Text(timerInterval: timerRange(startedAt: startedAt), countsDown: false)
                    .font(PaydayFont.displayLarge)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button(intent: EndShiftIntent()) {
                    Text("End")
                        .font(PaydayFont.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, PaydaySpacing.p4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(PaydayColor.primary)
            }
        }
        .padding(PaydaySpacing.p20)
    }
}
