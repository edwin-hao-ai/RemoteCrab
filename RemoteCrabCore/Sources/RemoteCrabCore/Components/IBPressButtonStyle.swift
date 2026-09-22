import SwiftUI

/// Shared pressed-state for tappable controls.
///
/// Plain buttons gave no feedback at all — a tap didn't light up or move,
/// so it read as unresponsive ("doesn't feel like a button"). This adds a
/// small scale plus a brief highlight on press.
public struct IBPressButtonStyle: ButtonStyle {
    public var scale: CGFloat
    public var highlight: Double

    public init(scale: CGFloat = 0.94, highlight: Double = 0.12) {
        self.scale = scale
        self.highlight = highlight
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Hit-test the label's whole bounds. A custom ButtonStyle
            // hit-tests the label's *content* shape, so a glass background
            // (transparent fill) leaves only the icon/text tappable — the
            // trailing half of a left-aligned card was dead.
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? highlight : 0)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
