import Foundation

/// The first time each Move (keyed by its stable per-type id, e.g.
/// "weekdaySwap") was ever shown to the user. The Moves engine that wrote
/// it is deleted, so nothing adds an entry any more; the stored ledger is
/// kept as it is and still syncs.
@Observable
final class MoveLedgerStore {
    private static let key = "com.szakacsmedia.payday.moveLedger"
    private let defaults: UserDefaults
    private(set) var revision = 0

    private(set) var firstShownAt: [String: Date] {
        didSet {
            revision &+= 1
            persist()
            PaydaySettingsSyncClock.touch()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.firstShownAt = Self.load(from: defaults)
    }

    /// Clears every ledger entry — debug/test convenience, mirrors the
    /// reset hooks on the app's other stores.
    func reset() {
        firstShownAt = [:]
    }

    func replaceFromSupabase(_ value: [String: Date]) {
        firstShownAt = value
    }

    private static func load(from defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(firstShownAt) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
