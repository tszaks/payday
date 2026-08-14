import SwiftData

/// The one SwiftData store, shared between the app and the widget
/// extension via the App Group container. Both processes open the exact
/// same file — the widget only ever reads, App Intents write. Only the
/// app process drives CloudKit sync of that file; the widget extension
/// passes cloudKitDatabase: .none so it never stands up a second sync
/// engine against the same store.
enum SharedModelContainer {
    private static let cloudKitContainerIdentifier = "iCloud.com.szakacsmedia.payday"

    static let shared: ModelContainer = {
        let url = AppGroup.containerURL.appendingPathComponent("Payday.sqlite")
        let cloudKitDatabase = Self.cloudKitDatabase
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: cloudKitDatabase)
        do {
            return try ModelContainer(for: TipEntry.self, PaycheckRecord.self, configurations: configuration)
        } catch {
            fatalError("Failed to load the shared Payday store: \(error)")
        }
    }()

    private static var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        #if WIDGET_EXTENSION
        return .none
        #elseif targetEnvironment(simulator)
        // Simulator builds may be unsigned or missing the iCloud
        // entitlements. SwiftData starts CloudKit during ModelContainer
        // creation, and that state otherwise terminates the app at launch.
        return .none
        #else
        return .private(cloudKitContainerIdentifier)
        #endif
    }
}
