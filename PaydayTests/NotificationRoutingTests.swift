import Testing
import Foundation
@testable import Payday

@Suite("Payday notification tap routing")
@MainActor
struct NotificationRoutingTests {
    // Made-up period: Mon Jul 13 through Sun Jul 19 2026, as seconds since 1970.
    private let start = Date(timeIntervalSince1970: 1_783_915_200)
    private let end = Date(timeIntervalSince1970: 1_784_433_600)

    private var userInfo: [AnyHashable: Any] {
        [
            PaydayPushScheduler.periodStartKey: start.timeIntervalSince1970,
            PaydayPushScheduler.periodEndKey: end.timeIntervalSince1970
        ]
    }

    @Test("both payday identifiers with a period land in that period's stub scan")
    func bothIdentifiersWithPeriodLandInScan() {
        for identifier in [PaydayPushScheduler.notificationIdentifier, PaydayPushScheduler.stubNudgeIdentifier] {
            #expect(NotificationDelegate.periodLanding(identifier: identifier, userInfo: userInfo)
                == .paycheckScan(periodStart: start, periodEnd: end))
        }
    }

    @Test("a payday push from an older build, with no period, lands in the current detail")
    func noUserInfoLandsInCurrentDetail() {
        for identifier in [PaydayPushScheduler.notificationIdentifier, PaydayPushScheduler.stubNudgeIdentifier] {
            #expect(NotificationDelegate.periodLanding(identifier: identifier, userInfo: [:]) == .currentDetail)
        }
    }

    @Test("the smart nudge is not routed by the period router")
    func smartNudgeIsNotAPeriodLanding() {
        #expect(NotificationDelegate.periodLanding(identifier: SmartNudgeScheduler.notificationIdentifier, userInfo: userInfo) == nil)
    }
}
