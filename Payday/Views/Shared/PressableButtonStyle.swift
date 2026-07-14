import SwiftUI

/// Subtle press-down feedback for tappable elements outside a List (which
/// already gets native row-highlight for free). Scale stays gentle since
/// this fires on every tap across the calendar grid.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: PaydayAnimation.microDuration), value: configuration.isPressed)
    }
}
