import AppIntents

/// Registering these as App Shortcuts is what surfaces LogTipsIntent and
/// PeriodTotalIntent across Siri, the Shortcuts app, Spotlight, and the
/// Action Button / Control Center shortcut pickers — all from this one
/// declaration, no per-surface code.
struct PaydayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogTipsIntent(),
            phrases: [
                "Log tips in \(.applicationName)",
                "Log a tip in \(.applicationName)"
            ],
            shortTitle: "Log Tips",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: PeriodTotalIntent(),
            phrases: [
                "What's my tip total in \(.applicationName)",
                "Check my tips in \(.applicationName)"
            ],
            shortTitle: "Period Total",
            systemImageName: "banknote"
        )
        AppShortcut(
            intent: StartShiftIntent(),
            phrases: [
                "Start my shift in \(.applicationName)",
                "Start shift in \(.applicationName)"
            ],
            shortTitle: "Start Shift",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: EndShiftIntent(),
            phrases: [
                "End my shift in \(.applicationName)",
                "End shift in \(.applicationName)"
            ],
            shortTitle: "End Shift",
            systemImageName: "stop.circle"
        )
    }
}
