import SwiftUI

/// Subtle press-down feedback for tappable elements outside a List (which
/// already gets native row-highlight for free). Scale stays gentle since
/// this fires on every tap across the calendar grid.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: PaydayAnimation.microDuration),
                value: configuration.isPressed
            )
    }
}
