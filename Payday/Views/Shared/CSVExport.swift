import SwiftUI
import UniformTypeIdentifiers

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
