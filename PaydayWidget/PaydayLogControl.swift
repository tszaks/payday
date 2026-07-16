import SwiftUI
import WidgetKit
import AppIntents

/// Control Center / Lock Screen / Action Button entry point — one press,
/// from anywhere, straight into the log sheet. Reuses OpenLogSheetIntent
/// (already the home-screen widget's "+" target), so there's exactly one
/// "open straight to logging" code path regardless of where the press
/// originated.
struct PaydayLogControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.szakacsmedia.payday.logControl") {
            ControlWidgetButton(action: OpenLogSheetIntent()) {
                Label("Log Tips", systemImage: "dollarsign.circle")
            }
        }
        .displayName("Log Tips")
        .description("Jump straight to logging a shift.")
    }
}
