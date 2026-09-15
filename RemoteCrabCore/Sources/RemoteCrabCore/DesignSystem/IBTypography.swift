import SwiftUI

/// RemoteCrab typography — SF Pro with the same hierarchy Apple uses
/// in iOS 26 / macOS Tahoe Pro apps. All technical readouts (latency,
/// FPS, bitrate) use SF Mono — the "professional broadcast gear"
/// signal that makes any UI feel pro.
public enum IBFont {

    // MARK: - Display (SF Pro Display)

    // iOS maps every token to a system Text Style so Dynamic Type
    // scales the whole app; macOS has no Dynamic Type, so the Mac
    // keeps the original fixed point sizes (Mac windows are sized to
    // them). The mono family below stays fixed on BOTH platforms:
    // technical readouts live inside fixed-width capsules and pills.
    #if os(iOS)

    /// Top of the page. Used for the "Trackpad" hero label.
    public static let displayLarge = Font.system(.largeTitle, design: .default, weight: .semibold)
        .leading(.tight)

    /// Mid-page title. App icon style.
    public static let displayMedium = Font.system(.title, design: .default, weight: .semibold)
        .leading(.tight)

    // MARK: - Headings (SF Pro Text)

    public static let titleLarge  = Font.system(.title2, design: .default, weight: .semibold)
    public static let titleMedium = Font.system(.headline, design: .default)
    public static let titleSmall  = Font.system(.subheadline, design: .default, weight: .semibold)

    // MARK: - Body

    public static let bodyLarge  = Font.system(.body, design: .default)
    public static let bodyMedium = Font.system(.callout, design: .default)
    public static let bodySmall  = Font.system(.footnote, design: .default)

    public static let caption = Font.system(.caption, design: .default)
        .leading(.tight)

    #else

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

    #endif

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