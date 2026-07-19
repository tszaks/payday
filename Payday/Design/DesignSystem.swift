// DesignSystem.swift
// Payday Design System — ported from Vero's Core/Design/DesignSystem.swift so the
// two apps share one visual language. See AskVero/ios/docs/VERO_VISION.md (the
// law) and Payday/docs/DESIGN.md (the translation). Values are kept identical
// to Vero's; only the type names are renamed and iOS-26-only floor lets the
// pre-26 fallback branches and command-bar/agent-status/composer tokens drop.
//
// Laws: one action color (Vero green #00B83F); white/black build structure;
// caution + error are the only warning signals; SF Pro only; authentic Apple
// glass for chrome only; light (alabaster/ink) and dark (obsidian) are
// co-equal.

import SwiftUI
import UIKit

// MARK: - Adaptive Color System

/// Light Mode: Alabaster base, pure white cards, ink text.
/// Dark Mode: Obsidian base, near-black cards, weighted white text.
enum PaydayColor {

    // MARK: - Core Backgrounds (Adaptive)

    /// Main app background. Light: Alabaster (#FAFAFA). Dark: Obsidian (#050505).
    static let background = Color(lightHex: "FAFAFA", darkHex: "050505")

    /// Card backgrounds that lift off the page.
    /// Light: Pure White (#FFFFFF). Dark: #121212.
    static let cardBackground = Color(lightHex: "FFFFFF", darkHex: "121212")

    /// Inset field / box surface — the grey that gives input fields, note
    /// fields, and grouped detail boxes a visible edge against the page.
    /// Matches Apple's secondarySystemBackground. Use for INSET fields and
    /// boxes, not for cards that lift off the page (those use cardBackground).
    static let fieldBackground = Color(lightHex: "F2F2F7", darkHex: "1C1C1E")

    // MARK: - Brand (one green, the only action color)

    /// Payday/Vero green — the single brand and action color (#00B83F).
    static let primary = Color(hex: "00B83F")
    /// Foreground for text/icons placed directly on the green.
    static let onPrimary = Color(hex: "FFFFFF")
    /// Foreground for text/icons placed directly on caution surfaces.
    static let onCaution = Color(lightHex: "FFFFFF", darkHex: "000000")
    /// Foreground for text/icons placed directly on error/red surfaces.
    static let onError = Color(hex: "FFFFFF")

    // MARK: - Semantic Colors

    /// Success = the one green.
    static let success = primary

    /// Caution — the only other warning accent, foreground-safe in both modes.
    static let caution = Color(lightHex: "E8590C", darkHex: "FF9F0A")

    /// Error red (both modes). In Payday: a paycheck that shorted you.
    static let error = Color(hex: "FF3B30")

    // MARK: - Text Colors (Adaptive)

    /// Primary text. Light: True Black (ink). Dark: Pure White.
    static let textPrimary = Color(lightHex: "000000", darkHex: "FFFFFF")

    /// Secondary text. Light: Medium Gray. Dark: iOS System Gray.
    static let textSecondary = Color(lightHex: "6B6B6B", darkHex: "8E8E93")

    /// Tertiary/disabled text.
    static let textTertiary = Color(lightHex: "AEAEAE", darkHex: "48484A")
}

// MARK: - Corner Radius Scale

enum PaydayRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 18
    static let xl: CGFloat = 24
    static let full: CGFloat = 9999
}

// MARK: - Spacing Scale (4-point base)

enum PaydaySpacing {
    static let p4: CGFloat = 4
    static let p8: CGFloat = 8
    static let p12: CGFloat = 12
    static let p16: CGFloat = 16
    static let p20: CGFloat = 20
    static let p24: CGFloat = 24
    static let p30: CGFloat = 30
    static let p32: CGFloat = 32
    static let p40: CGFloat = 40

    // Semantic mappings
    static let xxs = p4
    static let xs = p8
    static let sm = p12
    static let md = p16
    static let lg = p24
    static let xl = p32
}

// MARK: - Typography Scale
// SF Pro everywhere. Money uses SF Pro Rounded, heavy weight, fixed display
// sizes (like Apple Wallet) so amounts read as premium finance UI. UI text
// uses semantic Dynamic Type styles with bumped weights.

enum PaydayFont {

    // MARK: - Display Fonts (SF Pro Rounded, for money)
    // Fixed sizes — amounts stay readable, don't scale with Dynamic Type.
    static let displayXXL = Font.system(size: 60, weight: .heavy, design: .rounded)
    static let displayHero = Font.system(size: 48, weight: .heavy, design: .rounded)
    static let displayXL = Font.system(size: 40, weight: .heavy, design: .rounded)
    static let displayLarge = Font.system(size: 36, weight: .heavy, design: .rounded)
    static let displayMediumBlack = Font.system(size: 30, weight: .heavy, design: .rounded)
    static let displayMedium = Font.system(size: 24, weight: .heavy, design: .rounded)
    static let displayCompact = Font.system(size: 22, weight: .heavy, design: .rounded)
    static let displaySmall = Font.system(size: 20, weight: .bold, design: .rounded)

    // MARK: - Semantic Text (SF Pro, scales with Dynamic Type)
    static let largeTitle = Font.largeTitle.weight(.heavy)
    static let title = Font.title2.weight(.bold)
    static let title3 = Font.title3.weight(.bold)
    static let headline = Font.headline.weight(.bold)
    static let headlineBold = Font.headline.weight(.heavy)
    static let body = Font.body.weight(.semibold)
    static let bodySemibold = Font.body.weight(.bold)
    /// Every other body-ish token here is semibold or bolder — this is the
    /// one true regular weight, for paragraph copy (e.g. Insights) where
    /// stacking multiple semibold paragraphs reads as a wall of bold text.
    static let bodyRegular = Font.body
    static let callout = Font.callout.weight(.semibold)
    static let subheadline = Font.subheadline.weight(.semibold)
    static let subheadlineSemibold = Font.subheadline.weight(.bold)
    static let footnote = Font.footnote.weight(.semibold)
    static let caption = Font.caption.weight(.semibold)
    static let captionSemibold = Font.caption.weight(.bold)
    static let caption2 = Font.caption2.weight(.semibold)

    // MARK: - Small Text (fixed sizes for UI chrome — badges, labels)
    static let caption3 = Font.system(size: 10, weight: .semibold)

    // MARK: - Icon Sizes (fixed, for SF Symbols)
    static let iconSmall = Font.system(size: 14)
    static let iconMedium = Font.system(size: 18)
    static let iconLarge = Font.system(size: 24)
    static let iconXL = Font.system(size: 32)
}

// MARK: - Premium View Modifiers

extension View {

    /// Applies negative tracking for premium financial typography.
    func premiumTracking(_ value: CGFloat = -0.5) -> some View {
        self.tracking(value)
    }

    /// Native iOS 26 glass capsule. Payday's floor is 26.0, so there is no
    /// pre-26 fallback branch to carry.
    func paydayNativeGlassCapsule(interactive: Bool = true) -> some View {
        self
            .glassEffect(.regular.interactive(interactive), in: .capsule)
            .glassEffectTransition(UIAccessibility.isReduceMotionEnabled ? .materialize : .matchedGeometry)
    }

    /// Native iOS 26 glass circle.
    func paydayNativeGlassCircle(interactive: Bool = true) -> some View {
        self
            .glassEffect(.regular.interactive(interactive), in: .circle)
            .glassEffectTransition(UIAccessibility.isReduceMotionEnabled ? .materialize : .matchedGeometry)
    }

    /// Native iOS 26 rounded-rect glass.
    func paydayNativeGlassRoundedRect(cornerRadius: CGFloat, interactive: Bool = true) -> some View {
        self
            .glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: cornerRadius))
            .glassEffectTransition(.identity)
    }

    /// Premium 3-layer shadow system.
    /// Light Mode: soft diffusion (cloudy-day aesthetic).
    /// Dark Mode: minimal shadow — darkness itself is the shadow.
    func paydayPremiumShadow() -> some View {
        self.modifier(PaydayPremiumShadowModifier())
    }

    /// THE lifted card surface for the whole app. Every content card — the
    /// dashboard hero, an Insights block, a Periods row, the calendar — routes
    /// through this one modifier so they are literally identical, not merely
    /// similar. White that lifts off the alabaster page with the 3-layer
    /// shadow; the shadow (never a border) is the depth cue.
    func paydayCard(padding: CGFloat = PaydaySpacing.p20, cornerRadius: CGFloat = PaydayRadius.xl) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(PaydayColor.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .paydayPremiumShadow()
    }

    /// Premium spring animation curve — Apple's .smooth preset.
    func paydaySpring() -> Animation {
        .smooth
    }

    /// Snappier spring for quick, precise interactions — Apple's .snappy preset.
    func paydayPaperSpring() -> Animation {
        .snappy
    }
}

// MARK: - Premium Shadow Modifier

struct PaydayPremiumShadowModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .light {
            // Light Mode: 3-layer "Cloudy Day" diffusion. These opacities run
            // noticeably stronger than Vero's own literal values (byte-for-byte
            // ported here originally) — on Payday's actual white-card-on-#FAFAFA
            // surfaces, the ported numbers read as no elevation at all, cards
            // and the page background were indistinguishable. VERO_VISION's own
            // meta-rule licenses this: "if following a rule literally makes a
            // screen worse, the rule is being applied wrong — look at the
            // render." The background/card hex tokens themselves are correct
            // law and untouched; only the shadow needed to actually show up.
            content
                // Layer 1: Ambient occlusion (large, soft)
                .shadow(color: Color.black.opacity(0.04), radius: 32, x: 0, y: 16)
                // Layer 2: Gravity (the primary "lifted off the page" cue)
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                // Layer 3: Contact patch (tiny, sharp)
                .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
        } else {
            // Dark Mode: minimal — darkness is the shadow. Already correct
            // (obsidian cards read clearly against #050505); untouched.
            content
                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
        }
    }
}

// MARK: - Animation Timing Constants
// 100ms increments for consistency across the app.

enum PaydayAnimation {
    // MARK: - Duration Constants (seconds)

    /// Fast micro-interaction (100ms) — button taps, toggles.
    static let microDuration: TimeInterval = 0.1
    /// Quick transition (150ms) — list item stagger delay.
    static let quickDuration: TimeInterval = 0.15
    /// Standard transition (200ms) — fade in/out.
    static let standardDuration: TimeInterval = 0.2
    /// Modal/keyboard sync (300ms).
    static let modalDuration: TimeInterval = 0.3
    /// Premium spring response (400ms).
    static let premiumDuration: TimeInterval = 0.4
    /// Smooth transition (500ms) — longer easing.
    static let smoothDuration: TimeInterval = 0.5

    // MARK: - Spring Configurations (Apple WWDC "Designing Fluid Interfaces")

    /// Paper physics spring (snappy) — quick, precise interactions.
    static let paperSpring: Animation = .snappy
    /// Premium spring (smooth) — gentle transitions, e.g. amounts rolling.
    static let premiumSpring: Animation = .smooth
    /// Drawer spring — visible overshoot so a drawer lands with a small,
    /// playful bounce: livelier than snappy (bounce 0.15), shy of the
    /// full .bouncy preset (0.3) so it never reads as cartoonish.
    static let drawerSpring: Animation = .spring(duration: 0.5, bounce: 0.24)
}

// MARK: - Haptic Feedback

enum PaydayHaptics {
    /// Check if haptics should be disabled (e.g. Low Power Mode).
    private static var shouldSkipHaptics: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Light tap — navigation-level actions (tab switches, month changes).
    @MainActor
    static func lightTap() {
        guard !shouldSkipHaptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Medium feedback for confirmations.
    @MainActor
    static func medium() {
        guard !shouldSkipHaptics else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Success feedback — a real save (a tip, a paycheck).
    @MainActor
    static func success() {
        guard !shouldSkipHaptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Error feedback — failed validation or a save that couldn't complete.
    @MainActor
    static func error() {
        guard !shouldSkipHaptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Selection changed — for pickers, segmented toggles.
    @MainActor
    static func selection() {
        guard !shouldSkipHaptics else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Color Extension for Hex & Adaptive Colors

extension Color {
    /// Create a color from a hex string.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Create an adaptive color with different light/dark values.
    init(lightHex: String, darkHex: String) {
        self.init(UIColor { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .dark:
                return UIColor(Color(hex: darkHex))
            default:
                return UIColor(Color(hex: lightHex))
            }
        })
    }
}
