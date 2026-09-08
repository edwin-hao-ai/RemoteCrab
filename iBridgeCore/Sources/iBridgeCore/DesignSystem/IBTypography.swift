import SwiftUI

/// iBridge typography — SF Pro with the same hierarchy Apple uses
/// in iOS 26 / macOS Tahoe Pro apps. All technical readouts (latency,
/// FPS, bitrate) use SF Mono — the "professional broadcast gear"
/// signal that makes any UI feel pro.
public enum IBFont {

    // MARK: - Display (SF Pro Display)

    /// Top of the page. Used for the "Trackpad" hero label.
    public static let displayLarge = Font.system(size: 44, weight: .semibold, design: .default)
        .leading(.tight)

    /// Mid-page title. App icon style.
    public static let displayMedium = Font.system(size: 28, weight: .semibold, design: .default)
        .leading(.tight)

    // MARK: - Headings (SF Pro Text)

    public static let titleLarge  = Font.system(size: 22, weight: .semibold, design: .default)
    public static let titleMedium = Font.system(size: 17, weight: .semibold, design: .default)
    public static let titleSmall  = Font.system(size: 15, weight: .semibold, design: .default)

    // MARK: - Body

    public static let bodyLarge  = Font.system(size: 17, weight: .regular, design: .default)
    public static let bodyMedium = Font.system(size: 15, weight: .regular, design: .default)
    public static let bodySmall  = Font.system(size: 13, weight: .regular, design: .default)

    public static let caption = Font.system(size: 11, weight: .regular, design: .default)
        .leading(.tight)

    // MARK: - Mono (SF Mono)

    /// All technical readouts. The single most important font choice
    /// in the whole design system. Use it for: latency, FPS, bitrate,
    /// resolution, ISO, focus distance, packet counters.
    public static let monoLarge   = Font.system(size: 15, weight: .medium, design: .monospaced)
    public static let monoMedium  = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let monoSmall   = Font.system(size: 10, weight: .medium, design: .monospaced)

    /// Eyebrow / category labels — small caps feel.
    public static let eyebrowMono = Font.system(size: 10, weight: .semibold, design: .monospaced)
        .leading(.tight)
}

// MARK: - Tracking helpers

extension View {
    /// Apple's default tracking for SF Pro Display at large sizes.
    public func ibDisplayTracking() -> some View {
        self.tracking(-1.5)
    }

    /// Tracking for eyebrow mono labels (uppercase).
    public func ibEyebrowTracking() -> some View {
        self.tracking(1.6)
    }
}