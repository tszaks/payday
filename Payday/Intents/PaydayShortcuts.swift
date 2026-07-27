import AppIntents

/// Registering these as App Shortcuts is what surfaces LogTipsIntent and
/// PeriodTotalIntent across Siri, the Shortcuts app, Spotlight, and the
/// Action Button / Control Center shortcut pickers — all from this one
/// declaration, no per-surface code.
struct PaydayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogTipsIntent(),
            // Every phrase must contain the app name — Siri only matches
            // an App Shortcut when it hears which app you mean. More
            // spellings of the same intent = more sentences that land.
            phrases: [
                "Log tips in \(.applicationName)",
                "Log a tip in \(.applicationName)",
                "Log my tips in \(.applicationName)",
                "Log tips with \(.applicationName)",
                "Log my tips with \(.applicationName)",
                "Add tips to \(.applicationName)",
                "Log a shift in \(.applicationName)"
            ],
            shortTitle: "Log Tips",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: PeriodTotalIntent(),
            phrases: [
                "What's my tip total in \(.applicationName)",
                "Check my tips in \(.applicationName)",
                "How much have I made in \(.applicationName)",
                "What are my tips in \(.applicationName)",
                "Check my tips with \(.applicationName)"
            ],
            shortTitle: "Period Total",
            systemImageName: "banknote"
        )
        AppShortcut(
            intent: StartShiftIntent(),
            phrases: [
                "Start my shift in \(.applicationName)",
                "Start shift in \(.applicationName)",
                "Start my shift with \(.applicationName)",
                "Clock in with \(.applicationName)",
                "Clock in on \(.applicationName)",
                "Start a shift in \(.applicationName)"
            ],
            shortTitle: "Start Shift",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: EndShiftIntent(),
            phrases: [
                "End my shift in \(.applicationName)",
                "End shift in \(.applicationName)",
                "End my shift with \(.applicationName)",
                "Clock out with \(.applicationName)",
                "Clock out on \(.applicationName)",
                "Stop my shift in \(.applicationName)"
            ],
            shortTitle: "End Shift",
            systemImageName: "stop.circle"
        )
    }
}
