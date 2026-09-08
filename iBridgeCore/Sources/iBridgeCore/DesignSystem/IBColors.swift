import SwiftUI

/// iBridge color system — tuned for Apple's Liquid Glass design language.
///
/// All semantic colors automatically adapt to light/dark mode via
/// `Color.dynamic(_:dark:)` and respond to the user's Liquid Glass
/// transparency setting introduced in iOS 26.1+.
public enum IBColor {

    // MARK: - Surface

    /// Background canvas. Stays mostly transparent so Liquid Glass
    /// panels show their refraction effect.
    public static let canvas = Color.dynamic(
        light: Color(red: 0.96, green: 0.96, blue: 0.98),
        dark:  Color(red: 0.04, green: 0.04, blue: 0.06)
    )

    /// The "Liquid Glass" surface — translucent by design.
    /// Use `IBMaterial.glass` rather than this raw color in most cases.
    public static let glassTint = Color.dynamic(
        light: Color.white.opacity(0.55),
        dark:  Color.white.opacity(0.10)
    )

    // MARK: - Text

    public static let textPrimary   = Color.primary
    public static let textSecondary = Color.secondary
    public static let textTertiary  = Color.dynamic(
        light: Color.black.opacity(0.30),
        dark:  Color.white.opacity(0.30)
    )

    // MARK: - Accent

    /// Apple's System Blue — primary action color. Used for the
    /// stream button, modifier keys, and active toggles.
    public static let accent = Color.accentColor

    /// Tint used inside Liquid Glass containers so the glass
    /// picks up a subtle blue hue (Apple's own apps do this).
    public static let accentGlass = Color.dynamic(
        light: Color(red: 0.04, green: 0.52, blue: 1.00).opacity(0.85),
        dark:  Color(red: 0.25, green: 0.66, blue: 1.00).opacity(0.85)
    )

    // MARK: - Semantic

    public static let success = Color.dynamic(
        light: Color(red: 0.00, green: 0.53, blue: 0.35),
        dark:  Color(red: 0.20, green: 0.80, blue: 0.50)
    )

    public static let warning = Color.dynamic(
        light: Color(red: 1.00, green: 0.60, blue: 0.00),
        dark:  Color(red: 1.00, green: 0.70, blue: 0.20)
    )

    public static let error = Color.dynamic(
        light: Color(red: 0.86, green: 0.15, blue: 0.15),
        dark:  Color(red: 1.00, green: 0.27, blue: 0.27)
    )

    /// Recording red — the streaming "STOP" button color.
    public static let recording = Color(red: 1.00, green: 0.23, blue: 0.19)

    // MARK: - Dividers / borders

    public static let borderSubtle  = Color.primary.opacity(0.06)
    public static let borderRegular = Color.primary.opacity(0.10)
    public static let borderStrong  = Color.primary.opacity(0.18)
}

// MARK: - Light / dark helper

extension Color {
    /// Build a color whose light/dark variants are explicit.
    public static func dynamic(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        return Color(nsColor: NSColor(name: dynamicProviderName) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
                ? NSColor(dark)
                : NSColor(light)
        })
        #endif
    }
}

#if !canImport(UIKit)
import AppKit
private let dynamicProviderName = NSColor.Name("iBridge.DynamicColor")
#endif