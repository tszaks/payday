import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Periods and Calendar are the same job — history — told in two time
/// systems: a list of pay periods, or a month grid. One tab, one
/// NavigationStack, a segmented control choosing which telling is on screen.
enum HistoryLens: String, CaseIterable {
    case periods, calendar

    static let storageKey = "historyLens"

    /// Lets anything outside HistoryView (the Dashboard "See all" jump, the
    /// -InitialTab/-OpenCurrentPeriodDetail QA hooks) force the lens open to
    /// a specific one — @AppStorage in HistoryView reads this same
    /// UserDefaults key, so a write here is picked up like any other
    /// AppStorage writer would be.
    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

/// Defers the actual CSV build (and its temp-file write) until the share
/// sheet asks for the file's data, inside FileRepresentation's closure —
/// never while ShareLink itself is just rendering in the toolbar. Fixes a
/// real perf regression: the plain-URL version this replaced regenerated
/// the whole export and rewrote the file on every single body render.
/// Internal rather than private: DeleteAccountSheet offers the same export
/// as the alternative to losing your records, and it should hand the share
/// sheet the identical file this screen does rather than a second
/// implementation that could drift.
struct CSVExport: Transferable {
    /// Transferable values may move between executors. SwiftData reads stay
    /// on the main actor while the exported value remains safely Sendable.
    let makeCSV: @MainActor @Sendable () -> String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Payday-Export.csv")
            let csv = await export.makeCSV()
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct HistoryView: View {
    @AppStorage(HistoryLens.storageKey) private var lens: HistoryLens = .periods
    @State private var path = NavigationPath()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    private var calculator: PayPeriodCalculator {
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Lens", selection: $lens) {
                    Text("Periods").tag(HistoryLens.periods)
                    Text("Calendar").tag(HistoryLens.calendar)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PaydaySpacing.p16)
                .padding(.top, PaydaySpacing.p8)

                ZStack {
                    switch lens {
                    case .periods:
                        PeriodsView(path: $path)
                            .id(HistoryLens.periods)
                            .transition(lensTransition(edge: .leading))
                    case .calendar:
                        CalendarView()
                            .id(HistoryLens.calendar)
                            .transition(lensTransition(edge: .trailing))
                    }
                }
                .animation(reduceMotion ? nil : PaydayAnimation.paperSpring, value: lens)
            }
            .background(PaydayColor.background)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // The CSV itself is only built and written to disk when
                    // the share sheet actually asks for the file's data
                    // (inside CSVExport's FileRepresentation closure) —
                    // never on a plain render of this toolbar item. Present
                    // on both lenses: it exports the same periods data
                    // either way.
                    ShareLink(
                        item: CSVExport {
                            CSVExporter.export(
                                entries: allEntries,
                                paycheckRecords: paycheckRecords,
                                calculator: calculator
                            )
                        },
                        preview: SharePreview("Payday-Export.csv")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    /// Periods is index 0, Calendar is index 1 — each lens keeps a fixed
    /// home edge (periods on the leading side, calendar on the trailing
    /// side), so switching to calendar always slides it in from trailing
    /// while periods exits toward leading, and coming back reverses the
    /// same pair: periods re-enters from leading while calendar exits
    /// toward trailing. A single edge per lens (rather than a direction
    /// computed from the live `lens` value) is what makes both legs of the
    /// swap correct — the removal transition captures state from the render
    /// where that lens was still on screen, not the one it's switching to.
    /// Plain crossfade when the user has reduce-motion on.
    private func lensTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}
