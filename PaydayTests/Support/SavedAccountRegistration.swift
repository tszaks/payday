import Foundation
import SwiftData
import Testing
@testable import Payday

/// The App Group account state a test replaces, captured so it can be put
/// back.
///
/// The tests run inside the host app and share its App Group defaults. A
/// test that registers an account of its own first forgets the one already
/// registered, which on a simulator signed in to Payday erases that account's
/// sync checkpoint and its unsent deletions, and leaves every later suite
/// starting from the test's random account. Capture before the test, then
/// `restore(forgetting:)` the accounts it made.
struct SavedAccountRegistration: Sendable {
    private let registered: UUID?
    /// Every App Group value keyed by the registered account's id: its
    /// checkpoint and its pending deletions.
    private let saved: [String: Data]

    init() {
        registered = PaydaySyncState.registeredUserID
        saved = registered.map(Self.values(of:)) ?? [:]
    }

    func restore(forgetting created: [UUID]) {
        for id in created { PaydaySyncState.forget(userID: id) }
        guard let registered else { return }
        let defaults = AppGroup.defaults
        for key in Self.values(of: registered).keys where saved[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in saved { defaults.set(value, forKey: key) }
        PaydaySyncState.registerCurrentUser(registered)
    }

    private static func values(of account: UUID) -> [String: Data] {
        let suffix = account.uuidString.lowercased()
        return AppGroup.defaults.dictionaryRepresentation().reduce(into: [:]) { values, entry in
            if entry.key.hasSuffix(suffix), let data = entry.value as? Data {
                values[entry.key] = data
            }
        }
    }
}
