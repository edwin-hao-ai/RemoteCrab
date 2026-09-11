import AppKit
import SwiftUI
import iBridgeCore

/// First-launch flow for the Mac receiver. Shown when the user opens
/// iBridgeReceiver for the first time.
///
/// Why we need it: CGEventPost (used to inject mouse / keyboard events
/// from the iPhone to the Mac) requires **Accessibility** permission.
/// We make this discoverable upfront so the user doesn't get confused
/// why their input isn't working later.
///
/// Lifecycle:
///   • Shown once on first launch
///   • "Get Started" requests Accessibility permission
///   • Once granted, transitions to the normal UI
///   • "Re-request Accessibility permission" in Preferences resets the
///     flag and shows this flow again
struct FirstLaunchView: View {
    @Binding var didComplete: Bool
    @State private var hasAccessibility: Bool = false
    @State private var refreshing: Bool = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer().frame(height: IBSpace.xxxl.pt)

                // Hero icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 120, height: 120)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        }
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.white)
                }

                Spacer().frame(height: IBSpace.xxl.pt)

                // Explanation card
                VStack(alignment: .leading, spacing: 14) {
                    row(symbol: "1.circle.fill",
                        title: "Install iBridge Capture on your iPhone or iPad",
                        detail: "Free download from the App Store.")
                    row(symbol: "2.circle.fill",
                        title: "Grant Accessibility below",
                        detail: "We need it to drive your Mac's cursor & keyboard from your iPhone.")
                    row(symbol: "3.circle.fill",
                        title: "Both devices find each other automatically",
                        detail: "Tap the big button on iPhone — live preview appears here.")
                }
                .padding(20)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: IBSpace.xl.pt)

                // Status: Accessibility
                HStack(spacing: 8) {
                    Image(systemName: hasAccessibility
                          ? "checkmark.shield.fill"
                          : "exclamationmark.shield.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(hasAccessibility ? IBColor.success : IBColor.warning)
                    Text(hasAccessibility
                         ? IBLocale.Permission.accessibilityGranted
                         : IBLocale.Permission.accessibilityRequired)
                        .font(IBFont.bodyMedium)
                        .foregroundStyle(.primary)
                    Spacer()
                    if !hasAccessibility {
                        Button {
                            refresh()
                        } label: {
                            HStack(spacing: 6) {
                                if refreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.6)
                                        .frame(width: 10, height: 10)
                                }
                                Text(refreshing ? "Checking…" : IBLocale.Permission.recheck)
                                    .font(IBFont.bodySmall)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(refreshing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                }
                .padding(.horizontal, 24)

                Spacer()

                actionRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, IBSpace.xl.pt)
            }
        }
        .frame(width: 460, height: 600)
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
        // The user grants the permission in System Settings and comes
        // back — refresh as soon as our window becomes key again so the
        // status flips without needing the manual "Re-check" button.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }

    // MARK: - Action row

    /// Primary action full-width on top; the escape hatch ("Skip for
    /// now") sits centered below it instead of being squeezed to the
    /// trailing edge of an HStack.
    private var actionRow: some View {
        VStack(spacing: IBSpace.m.pt) {
            if hasAccessibility {
                Button {
                    didComplete = true
                } label: {
                    HStack(spacing: 6) {
                        Text("Open iBridge")
                            .font(IBFont.bodyMedium.weight(.semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background { Capsule().fill(Color.accentColor) }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    openAccessibilitySettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text(IBLocale.Permission.openSystemSettings)
                    }
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background { Capsule().fill(Color.accentColor) }
                }
                .buttonStyle(.plain)

                Button("Skip for now") { didComplete = true }
                    .font(IBFont.bodySmall)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: - Helpers

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IBFont.bodyMedium.weight(.medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        refreshing = true
        // Re-check after a brief delay so the user has time to toggle
        // the permission in System Settings.
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            hasAccessibility = AXIsProcessTrusted()
            refreshing = false
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }

    private var background: some View {
        IBGradient.brand
            .ignoresSafeArea()
    }
}
