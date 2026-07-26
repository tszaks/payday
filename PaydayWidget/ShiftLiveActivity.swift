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
                    }
                    .tint(PaydayColor.primary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(timerInterval: timerRange(startedAt: context.state.startedAt), countsDown: false)
                        .font(PaydayFont.displayCompact)
                        .monospacedDigit()
                        .foregroundStyle(PaydayColor.textPrimary)
                }
            } compactLeading: {
                Text("ON")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.primary)
            } compactTrailing: {
                Text(timerInterval: timerRange(startedAt: context.state.startedAt), countsDown: false)
                    .font(PaydayFont.caption)
                    .monospacedDigit()
                    .frame(width: 50)
                    .foregroundStyle(PaydayColor.textPrimary)
            } minimal: {
                Circle()
                    .fill(PaydayColor.primary)
                    .frame(width: 8, height: 8)
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

    private func lockScreenView(startedAt: Date) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ON SHIFT")
                    .font(PaydayFont.caption2)
                    .tracking(1)
                    .foregroundStyle(PaydayColor.primary)
                Text(timerInterval: timerRange(startedAt: startedAt), countsDown: false)
                    .font(PaydayFont.displayCompact)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                Text(sinceCaption(startedAt: startedAt))
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            Spacer()
            Button(intent: EndShiftIntent()) {
                Text("End")
            }
            .buttonStyle(.borderedProminent)
            .tint(PaydayColor.primary)
        }
        .padding()
    }
}
