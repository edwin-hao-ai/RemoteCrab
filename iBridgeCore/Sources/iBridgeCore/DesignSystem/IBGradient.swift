import SwiftUI

/// iBridge gradients — full-screen canvas backgrounds.
///
/// Every capture surface (trackpad, keyboard, onboarding, permissions)
/// paints the same dark canvas so moving between them never changes
/// the perceived "room". Keep this neutral: no saturated hues.
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
}
