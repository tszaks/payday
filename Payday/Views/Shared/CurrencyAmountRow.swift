import SwiftUI

/// A labeled, cents-based currency entry laid out as a row (label on the
/// left, digit-shift amount on the right). Same input behavior as
/// CurrencyAmountField, but sized to sit alongside a second one so a shift's
/// cash and credit tips can be entered together.
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
                .font(.body)
            Spacer()
            ZStack(alignment: .trailing) {
                Text(Money.string(fromCents: cents))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(cents == 0 ? Color.secondary : Color.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityHidden(true)

                TextField("", text: $digitsText)
                    .keyboardType(.numberPad)
                    .focused($isFocused)
                    .opacity(0.01)
                    .frame(maxWidth: 160, alignment: .trailing)
                    .accessibilityLabel("\(label) tips")
                    .accessibilityValue(Money.string(fromCents: cents))
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .opacity(isFocused ? 1 : 0)
        }
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
