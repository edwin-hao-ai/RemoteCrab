import SwiftUI

/// iBridge materials — Apple's Liquid Glass, properly wrapped.
///
/// In iOS 26+, use the actual `.glassEffect()` SwiftUI API.
/// On older systems, fall back to the existing Material hierarchy.
///
/// Reference: https://developer.apple.com/documentation/technologyoverviews/liquid-glass
public enum IBMaterial {

    /// Primary Liquid Glass surface. Use for cards, panels,
    /// floating control bars, the menu-bar dropdown, settings panels.
    ///
    /// On iOS 26+: real `.glassEffect()` with refraction and reflection.
    /// Below: `.regularMaterial` for close approximation.
    @ViewBuilder
    public static func glass<S: Shape>(
        in shape: S,
        tint: Color,
        interactive: Bool
    ) -> some View {
        GlassSurface(shape: shape, tint: tint, interactive: interactive)
    }

    /// Convenience: glass with default settings.
    @ViewBuilder
    public static func glass<S: Shape>(in shape: S) -> some View {
        glass(in: shape, tint: IBColor.accent.opacity(0.0), interactive: true)
    }

    /// Toolbar / chip variant — slightly more opaque than glass.
    @ViewBuilder
    public static func bar<S: Shape>(in shape: S) -> some View {
        BarMaterial(shape: shape)
    }
}

// MARK: - Liquid Glass surface

@available(iOS 26.0, macOS 26.0, *)
private struct GlassSurface<S: Shape>: View {
    let shape: S
    let tint: Color
    let interactive: Bool

    var body: some View {
        shape
            .fill(.clear)
            .glassEffect(.regular.interactive(interactive), in: shape)
            .overlay {
                shape
                    .stroke(IBColor.borderRegular, lineWidth: 0.5)
            }
            .overlay {
                shape
                    .fill(tint.opacity(0.10))
                    .blendMode(.overlay)
            }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct BarMaterial<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(.clear)
            .glassEffect(.regular, in: shape)
    }
}

// MARK: - Pre-iOS 26 fallback

/// Use when minimum deployment target is below iOS 26.
struct LegacyGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let interactive: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(tint.opacity(0.15), lineWidth: 0.5)
                    }
                    .opacity(interactive ? 1.0 : 0.85)
            }
    }
}

extension View {
    /// Backwards-compatible glass background for iOS < 26.
    public func legacyGlass(
        cornerRadius: CGFloat = 14,
        tint: Color = IBColor.accent,
        interactive: Bool = true
    ) -> some View {
        modifier(LegacyGlassModifier(
            cornerRadius: cornerRadius,
            tint: tint,
            interactive: interactive
        ))
    }
}