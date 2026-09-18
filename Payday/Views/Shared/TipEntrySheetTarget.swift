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
    /// Editing in the shift representation.
    ///
    /// A separate case rather than a generic one, because the two carry
    /// genuinely different amounts of information: a `TipEntry` is ONE ROW of
    /// a shift, so `LogTipSheet` has to seed from the anchor and then upgrade
    /// to the shift-level truth once `@Query` catches up. A `ShiftRecord` IS
    /// the whole shift, so there is nothing to upgrade -- the seed is already
    /// canonical. Collapsing them behind one case would force the record path
    /// through a reconciliation it does not need.
    case editShift(ShiftRecord)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let entry): "edit-\(entry.id)"
        // Distinct prefix: a projected row id is derived from the shift id, so
        // a shared prefix could collide two different sheets onto one
        // `sheet(item:)` identity.
        case .editShift(let record): "edit-shift-\(record.id)"
        }
    }
}
