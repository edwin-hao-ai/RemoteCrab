import SwiftUI
import UIKit
import RemoteCrabCore

/// App icon with a tinted-initial fallback while the PNG is in flight
/// (or when an app has no icon). Shared by the window switcher's cards
/// and the installed-app launcher, which live in the same target.
struct AppIconTile: View {
    let image: UIImage?
    let name: String
    let size: CGFloat

    private var initial: String {
        String(name.first(where: { !$0.isWhitespace }).map(String.init) ?? "?")
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(IBColor.accent.opacity(0.14))
                    .overlay {
                        Text(initial)
                            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                            .foregroundStyle(IBColor.accent)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Pressed feedback for a Liquid-Glass card or chip.
///
/// `IBPressButtonStyle` drives its feedback with `.brightness`, which the
/// iOS 26 `glassEffect` compositing layer ignores — on device the buttons
/// looked completely inert. This paints the highlight in the button's own
/// layer instead, where it always shows.
struct GlassPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Hit-test the whole label bounds: a custom ButtonStyle
            // hit-tests the label's content shape, so a left-aligned
            // icon + text leaves the trailing half untappable.
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
