import AppIntents

/// The widget's interactive "+" button target. Amounts need a keyboard, so
/// unlike LogTipsIntent this always opens the app — but it opens straight
/// to a blank log sheet, skipping tab-bar navigation entirely.
struct OpenLogSheetIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tip Entry"
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkCoordinator.shared.pendingLogTarget = .new(defaultDate: .now)
        return .result()
    }
}
