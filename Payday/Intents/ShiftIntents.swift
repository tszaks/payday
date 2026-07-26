import AppIntents
import ActivityKit

/// LiveActivityIntent (not plain AppIntent) runs in the APP process even
/// when invoked from a Control Center control or the Live Activity's own
/// button — that's what makes Activity.request legal from those surfaces
/// without opening the app UI first.
struct StartShiftIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Shift"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ShiftSessionStore.activeStart == nil else {
            return .result(dialog: "You're already on shift.")
        }
        ShiftSessionManager.start()
        return .result(dialog: "Shift started.")
    }
}

struct EndShiftIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Shift"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await ShiftSessionManager.end() != nil else {
            return .result(dialog: "No shift running.")
        }
        return .result(dialog: "Shift ended. Open Payday to log it.")
    }
}
