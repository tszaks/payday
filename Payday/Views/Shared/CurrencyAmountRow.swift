import SwiftUI

/// A labeled, cents-based currency entry as a self-contained rounded field
/// (label left, digit-shift amount right). Same input behavior as
/// CurrencyAmountField. The active field is ringed in the accent color so
/// it's obvious which one the keypad is driving.
struct CurrencyAmountRow: View {
    let label: String
    @Binding var cents: Int
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool
    @State private var digitsText: String = ""

    private static let maxDigits = 7 // caps at $99,999.99

    var body: some View {
        HStack {
            Text(label)
                .font(PaydayFont.body)
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer()
            ZStack(alignment: .trailing) {
                Text(Money.string(fromCents: cents))
                    .font(PaydayFont.displayMediumBlack)
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
                    .frame(maxWidth: 180, alignment: .trailing)
                    .accessibilityLabel("\(label) tips")
                    .accessibilityValue(Money.string(fromCents: cents))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(PaydayColor.fieldBackground, in: RoundedRectangle(cornerRadius: PaydayRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: PaydayRadius.md)
                .strokeBorder(
                    isFocused ? PaydayColor.primary : PaydayColor.textPrimary.opacity(0.08),
                    lineWidth: isFocused ? 2 : 1
                )
        )
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
