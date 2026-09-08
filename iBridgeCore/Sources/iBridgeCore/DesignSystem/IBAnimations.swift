import SwiftUI

/// iBridge motion — Apple Liquid Glass specs are spring-based.
///
/// Per Apple's HIG: linear and ease-in-out animations feel "web-y".
/// SwiftUI's `.spring(response:dampingFraction:)` matches the
/// physics of real glass.
public enum IBAnimation {

    /// Primary spring — UI elements appearing, layout changes,
    /// toggles, sliders.
    public static let standard: Animation = .spring(
        response: 0.4,
        dampingFraction: 0.85
    )

    /// Snappy — small interactions: button taps, key presses.
    public static let snappy: Animation = .spring(
        response: 0.28,
        dampingFraction: 0.78
    )

    /// Gentle — large panels sliding in/out, sheet presentations.
    public static let gentle: Animation = .spring(
        response: 0.55,
        dampingFraction: 0.92
    )

    /// Bouncy — celebratory moments (connection established, recording started).
    public static let bouncy: Animation = .spring(
        response: 0.5,
        dampingFraction: 0.55
    )
}

// MARK: - View modifiers

extension View {
    /// Apply Liquid Glass entrance animation when a view appears.
    public func ibAppear() -> some View {
        self
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .animation(IBAnimation.gentle, value: UUID())
    }

    /// Animated value-change spring — use on counters, latency numbers,
    /// progress bars. Every numeric change slides in from below.
    public func ibNumericSpring<V: Equatable>(value: V) -> some View {
        self.animation(IBAnimation.snappy, value: value)
    }
}