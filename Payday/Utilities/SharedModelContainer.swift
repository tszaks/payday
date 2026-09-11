import SwiftData

/// The replaceable on-device cache shared by the app, widget, and App
/// Intents. Supabase owns the durable account data; every process opens this
/// same App Group file with CloudKit disabled.
enum SharedModelContainer {
    private struct Resolution {
        let container: ModelContainer
        let didFallBackToMemory: Bool
    }

    private static let resolution: Resolution = {
        let url = AppGroup.containerURL.appendingPathComponent("Payday.sqlite")
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        do {
            return Resolution(
                container: try ModelContainer(
                    for: TipEntry.self,
                    PaycheckRecord.self,
                    configurations: configuration
                ),
                didFallBackToMemory: false
            )
        } catch {
            // A damaged or temporarily unavailable cache must never crash the
            // app or invite writes into a replacement file. Keep SwiftData's
            // environment valid with an in-memory container, then let the app
            // show a read-only recovery screen instead of RootView.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return Resolution(
                    container: try ModelContainer(
                        for: TipEntry.self,
                        PaycheckRecord.self,
                        configurations: fallback
                    ),
                    didFallBackToMemory: true
                )
            } catch {
                // The in-memory schema has no external failure mode. If this
                // fails too, the compiled model itself is invalid.
                preconditionFailure("Payday's SwiftData model could not be constructed.")
            }
        }
    }()

    static var shared: ModelContainer { resolution.container }
    static var openingFailed: Bool { resolution.didFallBackToMemory }
}
