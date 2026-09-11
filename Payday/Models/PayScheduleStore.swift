import Foundation

/// Owns the pay schedule (frequency + anchor payday) in UserDefaults.
/// Never SwiftData: the schedule is app configuration, not a record.
/// Pay periods are always derived from this at read time — never persisted
/// onto TipEntry — so changing it live-regroups existing entries.
@Observable
final class PayScheduleStore {
    private static let key = "com.szakacsmedia.payday.schedule"
    private let defaults: UserDefaults

    var schedule: PaySchedule? {
        didSet {
            persist()
            PaydaySettingsSyncClock.touch()
        }
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        self.schedule = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> PaySchedule? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PaySchedule.self, from: data)
    }

    private func persist() {
        guard let schedule else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        if let data = try? JSONEncoder().encode(schedule) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
