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
                // One composed canvas instead of content scattered across
                // the island's top flanks and bottom edge (which leaves a
                // dead black band in the middle): the bottom region owns
                // everything, so the expanded island collapses to a tight
                // two-row card — the lock screen's exact grammar.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: PaydaySpacing.p8) {
                        HStack(alignment: .firstTextBaseline) {
                            HStack(spacing: PaydaySpacing.p8) {
                                Image("IslandMark")
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 16)
                                    .foregroundStyle(PaydayColor.primary)
                                Text("ON SHIFT")
                                    .font(PaydayFont.caption2)
                                    .tracking(1.2)
                                    .foregroundStyle(PaydayColor.primary)
                                    .fixedSize()
                            }
                            Spacer()
                            Text(sinceCaption(startedAt: context.state.startedAt))
                                .font(PaydayFont.caption2)
                                .foregroundStyle(PaydayColor.textTertiary)
                        }

                        HStack(alignment: .center, spacing: PaydaySpacing.p12) {
                            Text(timerInterval: timerRange(startedAt: context.state.startedAt), countsDown: false)
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
                    .padding(.horizontal, PaydaySpacing.p4)
                    .padding(.top, PaydaySpacing.p8)
                }
            } compactLeading: {
                // Apple's compact grammar (Timer: orange glyph + orange
                // countdown): identity leading, metric in the accent
                // trailing. The identity is the actual app icon mark
                // (Tyler's call) — never a dollar sign, that's Vero.
                Image("IslandMark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 20)
                    .foregroundStyle(PaydayColor.primary)
            } compactTrailing: {
                Text(timerInterval: timerRange(startedAt: context.state.startedAt), countsDown: false)
                    .font(PaydayFont.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.primary)
                    // Text(timerInterval:) reserves width for the WIDEST
                    // string the range allows; a sub-10h ceiling drops a
                    // reserved digit so a young shift's "0:07" doesn't sit
                    // in an "11:59:59"-wide box.
                    .frame(maxWidth: 52, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } minimal: {
                Image("IslandMark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                    .foregroundStyle(PaydayColor.primary)
            }
        }
    }

    /// Twelve hours out is far past any real shift — just a ceiling so
    /// Text(timerInterval:) has a bounded range to render against.
    private func timerRange(startedAt: Date) -> ClosedRange<Date> {
        // 9:59:59 is the ceiling on purpose: past 9h59m the range would
        // grow the timer to eight characters and the Dynamic Island
        // reserves that width all shift long (see compactTrailing).
        startedAt...startedAt.addingTimeInterval(10 * 3600 - 1)
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
        ShiftLockScreenView(startedAt: startedAt, range: timerRange(startedAt: startedAt))
    }
}
/// The lock screen face: header (dot + kicker, since-caption trailing) over
/// the big ticking timer. The timer is ALWAYS the ticking clock — no
/// relative-style or since-time stand-ins (Tyler, 2026-07-27: "nothing
/// except the ticking clock"). On dimmed/Always-On screens the system
/// renders its own minute-granularity form of this timer; that's Apple's
/// floor and we take it rather than substituting different content.
private struct ShiftLockScreenView: View {
    let startedAt: Date
    let range: ClosedRange<Date>

    var body: some View {
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
                Text("since \(startedAt.formatted(.dateTime.hour().minute()))")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
            }

            HStack(alignment: .center, spacing: PaydaySpacing.p12) {
                Text(timerInterval: range, countsDown: false)
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
