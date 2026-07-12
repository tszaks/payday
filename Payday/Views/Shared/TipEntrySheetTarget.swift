import Foundation

/// Single sheet(item:) enum driving both "log a new tip" and "edit an
/// existing entry" from any screen, so no screen mixes sheet(isPresented:)
/// and sheet(item:) for the same concern.
enum TipEntrySheetTarget: Identifiable {
    case new(defaultDate: Date)
    case edit(TipEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let entry): "edit-\(entry.id)"
        }
    }
}
