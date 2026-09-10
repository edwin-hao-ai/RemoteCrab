import AppKit
import Combine
import CoreGraphics
import SwiftUI
import iBridgeCore

/// The Mac menu bar's popover content. V0.2 — designed to match
/// the production quality of macOS utility apps (Linear, 1Password,
/// Tailscale, Raycast, CleanMyMac).
///
/// Design principles applied:
/// - **`.regularMaterial` background** for the NSVisualEffectView-like
///   frosted glass effect (Apple's MenuBarExtra `.window` style
///   provides this for free).
/// - **8pt corner radius**, 0.5pt hairline border, drop shadow.
/// - **Sectioned layout**: header → live preview → toggles → actions
///   → footer. Real macOS menus are heavily sectioned.
/// - **Native macOS toggles**, not custom switches.
/// - **Keyboard shortcuts** right-aligned in SF Mono, gray.
/// - **Signal-bars icon** as a status indicator (more informative
///   than a dot — shows "weak/medium/strong" by the number of bars).
/// - **SF Symbols hierarchical** for variable visual weight.
struct MenuBarMenu: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            streamRow
            Divider().opacity(0.4)
            togglesSection
            Divider().opacity(0.4)
            actionsSection
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("iBridge")
                    .font(IBFont.titleMedium)
                    .foregroundStyle(.primary)
                Spacer()
                statusPill
            }
            deviceRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(statusLabel)
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.primary)
                .ibEyebrowTracking()
        }
    }

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(session.discovered.first?.name ?? "—")
                .font(IBFont.bodySmall)
                .foregroundStyle(.primary)
            Spacer()
            if case .streaming(_, let ms) = session.state {
                Text("\(ms) ms")
                    .font(IBFont.monoSmall)
                    .foregroundStyle(statusColor)
            } else {
                Text("OFFLINE")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.secondary)
                    .ibEyebrowTracking()
            }
        }
    }

    // MARK: - Stream row

    @ViewBuilder
    private var streamRow: some View {
        if case .streaming(_, _) = session.state,
           let md = session.metadata {
            HStack(spacing: 12) {
                // Mini live preview placeholder
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.20, green: 0.40, blue: 0.85),
                            Color(red: 0.85, green: 0.45, blue: 0.65)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if let cg = session.latestFrame {
                        Image(cg, scale: 1, label: Text("Preview"))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 3) {
                                Circle().fill(IBColor.recording).frame(width: 4, height: 4)
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background {
                                Capsule().fill(.black.opacity(0.6))
                            }
                            .padding(6)
                        }
                        Spacer()
                    }
                }
                .frame(width: 80, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(md.resolutionLabel)
                            .font(IBFont.monoSmall)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("\(md.fps) fps")
                            .font(IBFont.monoSmall)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("\(md.bitrateBps / 1_000_000) Mbps")
                            .font(IBFont.monoSmall)
                            .foregroundStyle(.primary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            // Offline state — show a single hint row
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Waiting for an iPhone…")
                    .font(IBFont.bodySmall)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(spacing: 0) {
            sectionHeader("FEATURES")
            ToggleRow(icon: "camera.fill",
                      title: "Camera",
                      subtitle: "Live iPhone feed",
                      isOn: featureBinding(.camera, \.cameraOn))
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "mic.fill",
                      title: "Microphone",
                      subtitle: "Stream iPhone mic",
                      isOn: featureBinding(.microphone, \.micOn))
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "hand.point.up.left.fill",
                      title: "Trackpad",
                      subtitle: "Control Mac cursor",
                      isOn: featureBinding(.trackpad, \.trackpadOn))
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "keyboard",
                      title: "Keyboard",
                      subtitle: "Type on the Mac",
                      isOn: featureBinding(.keyboard, \.keyboardOn))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("ACTIONS")
            ActionRow(icon: "rectangle.on.rectangle",
                      title: "Open Control Panel",
                      shortcut: "⌘P")
            ActionRow(icon: "macwindow",
                      title: "Open Preview Window",
                      shortcut: "⌘⇧P")
            ActionRow(icon: "gear",
                      title: "Preferences…",
                      shortcut: "⌘,")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("iBridge v0.2 · Apple Native + Liquid Glass")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.secondary)
                .ibEyebrowTracking()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(IBFont.eyebrowMono)
            .foregroundStyle(.secondary)
            .ibEyebrowTracking()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    /// Live binding to the iPhone's feature state. Reads come from the
    /// latest `featureState` snapshot; writes send a `featureControl`
    /// frame. Until the first snapshot arrives the toggle shows off
    /// and writes are dropped by `ReceiverSession` when disconnected.
    private func featureBinding(
        _ feature: IBFeature,
        _ keyPath: KeyPath<FeatureStateSnapshot, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { session.featureState?[keyPath: keyPath] ?? false },
            set: { session.setFeature(feature, $0) }
        )
    }

    // Status derived from the live session state.
    private var statusLabel: String {
        switch session.state {
        case .searching:        return "LOOKING"
        case .connecting:       return "CONNECTING"
        case .streaming:        return "LIVE"
        case .error:            return "OFFLINE"
        }
    }

    private var statusIcon: String {
        switch session.state {
        case .searching:        return "antenna.radiowaves.left.and.right"
        case .connecting:       return "antenna.radiowaves.left.and.right"
        case .streaming:        return "circle.fill"
        case .error:            return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .searching:        return .orange
        case .connecting:       return .orange
        case .streaming:        return .green
        case .error:            return .red
        }
    }
}

// MARK: - Toggle row

private struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(IBFont.bodySmall)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - Action row

private struct ActionRow: View {
    let icon: String
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.primary)
            Text(title)
                .font(IBFont.bodySmall)
                .foregroundStyle(.primary)
            Spacer()
            Text(shortcut)
                .font(IBFont.monoSmall)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}