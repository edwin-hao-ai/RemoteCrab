import SwiftUI

/// iBridge gradients — full-screen canvas backgrounds.
///
/// `canvasDark` is the neutral iOS capture-surface canvas: every
/// capture surface (trackpad, keyboard, onboarding, permissions)
/// paints the same dark canvas so moving between them never changes
/// the perceived "room". `brand` is the saturated Mac receiver
/// backdrop.
public enum IBGradient {

    /// Full-screen dark canvas behind every iOS capture surface.
    public static let canvasDark = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.05, blue: 0.10),
            Color(red: 0.10, green: 0.05, blue: 0.16)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Mac receiver brand backdrop — deep blue → violet → plum.
    /// Used behind the control panel, connection test, preview
    /// surfaces and the first-launch flow. Unlike `canvasDark`
    /// this one is deliberately saturated; it shows through the
    /// Liquid Glass cards and gives the Mac app its identity.
    public static let brand = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.14, blue: 0.36),
            Color(red: 0.42, green: 0.10, blue: 0.50),
            Color(red: 0.20, green: 0.05, blue: 0.30)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
