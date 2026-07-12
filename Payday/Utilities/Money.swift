import Foundation
import SwiftUI
import UIKit

enum Money {
    static func string(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD"))
    }
}

extension Color {
    /// Pure white/black by light-vs-dark only. UIKit's `.systemBackground`
    /// resolves to an "elevated" dark gray inside sheets — this bypasses
    /// that so sheets stay exactly on the app's white/black/accent palette.
    static let paydaySurface = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
}
