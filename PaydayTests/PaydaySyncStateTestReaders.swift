import Foundation
@testable import Payday

extension PaydaySyncState {
    /// The shift restore queue, for tests that assert on it. The sync pass
    /// reads the queue off the checkpoint it already holds, so the app itself
    /// has no use for an accessor.
    static func pendingShiftRestores(for userID: UUID) -> [UUID: Date] {
        snapshot(for: userID).pendingShiftRestores
    }
}
