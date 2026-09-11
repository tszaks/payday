import SwiftUI

/// Carries the user's Appearance choice into a presented sheet.
///
/// `preferredColorScheme` is a SwiftUI *preference*, not an environment
/// value: it travels UP to its hosting controller rather than down through
/// the view tree. A sheet is presented in its own hosting controller, so the
/// `.preferredColorScheme` set once on the app root in PaydayApp never
/// reaches it — the sheet renders in whatever scheme it inherited at the
/// moment it appeared and then stays there.
///
/// That produced a visible bug: changing Appearance from inside Settings
/// recolored everything behind the sheet and left the Settings sheet itself
/// in the old scheme. It also meant that under "Automatic", the system's own
/// sunset flip would skip any sheet that was already open.
///
/// Every sheet root gets this. Environment DOES cross into a sheet, so
/// reading the store here re-evaluates live and re-emits the preference into
/// the sheet's own hosting controller.
private struct PaydayAppearanceModifier: ViewModifier {
    @Environment(UserPreferencesStore.self) private var preferencesStore

    func body(content: Content) -> some View {
        content.preferredColorScheme(preferencesStore.appearance.colorScheme)
    }
}

extension View {
    /// Apply to the root of every `.sheet` / `.fullScreenCover` content.
    /// See PaydayAppearanceModifier for why the app-root modifier isn't enough.
    func paydayAppearance() -> some View {
        modifier(PaydayAppearanceModifier())
    }
}
