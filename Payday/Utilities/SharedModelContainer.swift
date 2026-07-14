import SwiftData

/// The one SwiftData store, shared between the app and the widget
/// extension via the App Group container. Both processes open the exact
/// same file — the widget only ever reads, App Intents write. Only the
/// app process drives CloudKit sync of that file; the widget extension
/// passes cloudKitDatabase: .none so it never stands up a second sync
/// engine against the same store.
enum SharedModelContainer {
    static let shared: ModelContainer = {
        let url = AppGroup.containerURL.appendingPathComponent("Payday.sqlite")
        #if WIDGET_EXTENSION
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none
        #else
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .private("iCloud.com.szakacsmedia.payday")
        #endif
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: cloudKitDatabase)
        do {
            return try ModelContainer(for: TipEntry.self, PaycheckRecord.self, configurations: configuration)
        } catch {
            fatalError("Failed to load the shared Payday store: \(error)")
        }
    }()
}
