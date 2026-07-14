import SwiftUI

/// Cents-based currency entry: digits shift in from the right exactly like
/// Apple's own currency fields (Wallet, Cash). The visible text is always
/// derived from `cents`, never parsed from a raw string as a Double.
struct CurrencyAmountField: View {
    @Binding var cents: Int
    var autoFocus: Bool = true

    @FocusState private var isFocused: Bool
    @State private var digitsText: String = ""

    private static let maxDigits = 7 // caps at $99,999.99

    var body: some View {
        ZStack {
            Text(Money.string(fromCents: cents))
                .font(PaydayFont.displayHero)
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityHidden(true)

            TextField("", text: $digitsText)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .opacity(0.01)
                .accessibilityLabel("Tip amount")
                .accessibilityValue(Money.string(fromCents: cents))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear {
            digitsText = cents == 0 ? "" : String(cents)
            if autoFocus { isFocused = true }
        }
        .onChange(of: digitsText) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxDigits))
            if filtered != newValue { digitsText = filtered }
            cents = Int(filtered) ?? 0
        }
    }
}
