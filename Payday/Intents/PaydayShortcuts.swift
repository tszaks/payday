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
    }
}
