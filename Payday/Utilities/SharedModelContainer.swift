import SwiftData

/// The one SwiftData store, shared between the app and the widget
/// extension via the App Group container. Both processes open the exact
/// same file — the widget only ever reads, App Intents write.
enum SharedModelContainer {
    static let shared: ModelContainer = {
        let url = AppGroup.containerURL.appendingPathComponent("Payday.sqlite")
        let configuration = ModelConfiguration(url: url)
        do {
            return try ModelContainer(for: TipEntry.self, PaycheckRecord.self, configurations: configuration)
        } catch {
            fatalError("Failed to load the shared Payday store: \(error)")
        }
    }()
}
