import Foundation

/// Single sheet(item:) enum driving both "log a new tip" and "edit an
/// existing entry" from any screen, so no screen mixes sheet(isPresented:)
/// and sheet(item:) for the same concern.
enum TipEntrySheetTarget: Identifiable {
    /// clockIn/clockOut seed the Started/Ended pickers directly — used when
    /// a live shift session just ended and its exact punches are already
    /// known, rather than left for the picker's usual lunch/dinner defaults.
    case new(defaultDate: Date, clockIn: Date? = nil, clockOut: Date? = nil)
    case edit(TipEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let entry): "edit-\(entry.id)"
        }
    }
}
