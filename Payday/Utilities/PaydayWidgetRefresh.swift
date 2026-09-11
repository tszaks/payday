import WidgetKit

/// WidgetKit never watches the shared store itself — nothing refreshes the
/// Home Screen widget without an explicit nudge. Call this after any write
/// that could change what it shows: a tip logged, edited, deleted, or
/// undone; a paycheck entered; the schedule changed (period boundaries move
/// the widget's numbers too). Cheap to call often — the system coalesces
/// reload requests, so there's no need to be stingy about it.
enum PaydayWidgetRefresh {
    static func request() {
        WidgetCenter.shared.reloadTimelines(ofKind: "PaydayWidget")
    }
}
