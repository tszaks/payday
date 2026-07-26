import SwiftUI
import WidgetKit
import AppIntents

/// Control Center / Lock Screen / Action Button entry points for the shift
/// session. A single state-aware control (label switching between "Start
/// Shift"/"End Shift" off a ControlValueProvider reading ShiftSessionStore)
/// was tried first; AppIntentControlConfiguration's value-provider plumbing
/// fought the API hard enough that two plain StaticControlConfiguration
/// controls — exactly PaydayLogControl's own proven shape — won on
/// correctness. Both are always offered; StartShiftIntent/EndShiftIntent
/// each guard against the wrong state themselves (see ShiftIntents.swift),
/// so tapping the "wrong" one is a no-op dialog, never a corrupted session.
struct PaydayStartShiftControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.szakacsmedia.payday.startShiftControl") {
            ControlWidgetButton(action: StartShiftIntent()) {
                Label("Start Shift", systemImage: "timer")
            }
        }
        .displayName("Start Shift")
        .description("Punch in and start the Live Activity.")
    }
}

struct PaydayEndShiftControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.szakacsmedia.payday.endShiftControl") {
            ControlWidgetButton(action: EndShiftIntent()) {
                Label("End Shift", systemImage: "stop.circle")
            }
        }
        .displayName("End Shift")
        .description("Punch out and log the shift.")
    }
}
