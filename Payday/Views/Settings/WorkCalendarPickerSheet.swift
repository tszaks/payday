import SwiftUI

/// Presented once, right after calendar access is granted from Settings —
/// plain, text-forward rows grouped by source (iCloud, Google, etc.), no
/// color dots. Designate, never decipher: this only asks WHICH calendar,
/// never looks inside any of them.
struct WorkCalendarPickerSheet: View {
    let calendars: [(id: String, title: String, sourceTitle: String)]
    let onSelect: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var sourceTitles: [String] {
        Set(calendars.map(\.sourceTitle)).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sourceTitles, id: \.self) { sourceTitle in
                    Section(sourceTitle) {
                        ForEach(calendars.filter { $0.sourceTitle == sourceTitle }, id: \.id) { calendar in
                            Button {
                                onSelect(calendar.id, calendar.title)
                                dismiss()
                            } label: {
                                Text(calendar.title)
                                    .font(PaydayFont.body)
                                    .foregroundStyle(PaydayColor.textPrimary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .listRowBackground(PaydayColor.fieldBackground)
            .navigationTitle("Choose a Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(PaydayColor.background)
    }
}
