import AppKit
import Combine
import CoreGraphics
import SwiftUI
import RemoteCrabCore

/// The Mac menu bar's popover content. V0.2 — designed to match
/// the production quality of macOS utility apps (Linear, 1Password,
/// Tailscale, Raycast, CleanMyMac).
///
/// Design principles applied:
/// - **Frosted-glass background + window corner radius** come free
///   from `MenuBarExtra(.window)` — we only add a 0.5pt hairline
///   border, not a second material layer.
/// - **Sectioned layout**: header → live preview → toggles → actions
///   → footer. Real macOS menus are heavily sectioned.
/// - **Native macOS toggles**, not custom switches.
/// - **Keyboard shortcuts** right-aligned in SF Mono, gray.
/// - **Signal-bars icon** as a status indicator (more informative
///   than a dot — shows "weak/medium/strong" by the number of bars).
/// - **SF Symbols hierarchical** for variable visual weight.
struct MenuBarMenu: View {
    @EnvironmentObject private var session: ReceiverSession
    @EnvironmentObject private var setupStatus: SetupStatus
    @Environment(\.openWindow) private var openWindow
    @AppStorage("remotecrab.didFirstLaunch") private var didFirstLaunch: Bool = false
    @State private var showManualConnect = false
    @State private var manualAddress = ""

    var body: some View {
        VStack(spacing: 0) {
            // Setup-incomplete nudge. Disappears once Accessibility is
            // granted and the camera extension is active — the two gates
            // without which the product doesn't work.
            if didFirstLaunch && !setupStatus.isComplete {
                finishSetupRow
                Divider().opacity(0.4)
            }
            header
            Divider().opacity(0.4)
            if showsDevicePicker {
                devicesSection
                Divider().opacity(0.4)
            }
            streamRow
            Divider().opacity(0.4)
            togglesSection
            Divider().opacity(0.4)
            actionsSection
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 320)
        // Refreshing setup state on every popover open keeps the
        // "Finish Setup…" row honest without an always-on poll. A flip
        // during an open causes exactly one re-size, not a loop.
        .onAppear { setupStatus.refresh() }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .alert(LocalizedStringKey(IBLocale.Connection.connectManually),
               isPresented: $showManualConnect) {
            TextField("192.168.1.5:8765", text: $manualAddress)
            Button(IBLocale.Connection.connect) { connectManually() }
            Button(IBLocale.Connection.cancel, role: .cancel) {}
        } message: {
            Text(IBLocale.Connection.manualHint)
        }
    }

    /// Parse "host[:port]" (port defaults to the iPhone's fixed port).
    private func connectManually() {
        let trimmed = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: ":")
        let host = String(parts.first ?? "")
        let port = parts.count > 1 ? UInt16(parts[1]) : nil
        session.connectManually(host: host, port: port ?? 8765)
    }

    // MARK: - Finish Setup row

    /// Reopens the setup assistant: clearing the first-launch flag makes
    /// the root window swap MainWindowView for the wizard, then we just
    /// bring that window forward.
    private var finishSetupRow: some View {
        ActionRow(icon: "checklist",
                  title: LocalizedStringKey(IBLocale.Setup.finishSetup),
                  shortcut: "",
                  help: LocalizedStringKey(IBLocale.Setup.finishSetupHelp),
                  action: {
                      didFirstLaunch = false
                      openWindowActivating(id: "root")
                  })
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("RemoteCrab")
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
        // The popover follows the system appearance, so the pill text
        // must adapt (the default white is for dark canvases).
        IBStatusPill(status: session.state.statusPillStatus, foreground: .primary)
    }

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(session.state.phoneName ?? session.discovered.first?.name ?? "—")
                .font(IBFont.bodySmall)
                .foregroundStyle(.primary)
            Spacer()
            if case .streaming(_, let ms) = session.state {
                Text(IBLocale.Status.latency(ms))
                    .font(IBFont.monoSmall)
                    .foregroundStyle(statusColor)
                if let md = session.metadata {
                    Text("·")
                        .font(IBFont.monoSmall)
                        .foregroundStyle(.secondary)
                    Text(IBFormat.bitrate(bps: md.bitrateBps))
                        .font(IBFont.monoSmall)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(IBLocale.Status.offline)
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
                        Image(cg, scale: 1, label: Text(IBLocale.Preview.title))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    if session.latestFrame != nil {
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
                        Text(IBFormat.bitrate(bps: md.bitrateBps))
                            .font(IBFont.monoSmall)
                            .foregroundStyle(.primary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 74)
        } else {
            // Offline state — show a single hint row. The row is a FIXED
            // height and the text is one line: a `MenuBarExtra(.window)`
            // popover re-sizes (and animates) whenever its content height
            // changes, which produced a looping motion as the state text
            // changed during the reconnect loop.
            HStack(spacing: 8) {
                if case .error = session.state {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    // A live ProgressView spinner made the MenuBarExtra
                    // window re-layout every frame (visible drift), so a
                    // static glyph is used instead.
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                Text(session.state.message)
                    .font(IBFont.bodySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if case .error = session.state {
                    Button(IBLocale.Error.retry) { session.retryNow() }
                        .font(IBFont.bodySmall)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 74)
        }
    }

    // MARK: - Devices (bidirectional pairing)

    /// Show the discovered-phone picker whenever we're not in a live or
    /// in-flight session and there's at least one phone to pick. First
    /// contact is explicit: the user taps Connect here, then approves
    /// the pairing card on the iPhone.
    private var showsDevicePicker: Bool {
        if session.discovered.isEmpty { return false }
        switch session.state {
        case .streaming, .connecting, .handshaking, .awaitingApproval:
            return false
        case .searching, .error:
            return true
        }
    }

    private var devicesSection: some View {
        VStack(spacing: 0) {
            sectionHeader(LocalizedStringKey(IBLocale.Connection.devicesSection))
            ForEach(session.discovered) { phone in
                HStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, alignment: .center)
                        .foregroundStyle(.primary)
                    Text(phone.name)
                        .font(IBFont.bodySmall)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if session.isPaired(phone) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .help(Text(LocalizedStringKey(IBLocale.Connection.pairedBadge)))
                    }
                    Spacer()
                    Button(LocalizedStringKey(IBLocale.Connection.connect)) {
                        session.connectTo(phone)
                    }
                    .font(IBFont.bodySmall)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(height: 28)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        let connected = session.featureState != nil
        return VStack(spacing: 0) {
            sectionHeader(LocalizedStringKey(IBLocale.MenuBar.featuresSection))
            ToggleRow(icon: "camera.fill",
                      title: IBLocale.Mode.camera,
                      subtitle: connected ? LocalizedStringKey(IBLocale.MenuBar.cameraSubtitle)
                                         : LocalizedStringKey(IBLocale.Status.connectIPhoneFirst),
                      isOn: featureBinding(.camera, \.cameraOn),
                      isEnabled: connected)
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "mic.fill",
                      title: IBLocale.A11y.microphone,
                      subtitle: connected ? LocalizedStringKey(IBLocale.MenuBar.micSubtitle)
                                         : LocalizedStringKey(IBLocale.Status.connectIPhoneFirst),
                      isOn: featureBinding(.microphone, \.micOn),
                      isEnabled: connected)
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "hand.point.up.left.fill",
                      title: IBLocale.Mode.trackpad,
                      subtitle: connected ? LocalizedStringKey(IBLocale.MenuBar.trackpadSubtitle)
                                         : LocalizedStringKey(IBLocale.Status.connectIPhoneFirst),
                      isOn: featureBinding(.trackpad, \.trackpadOn),
                      isEnabled: connected)
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "keyboard",
                      title: IBLocale.Mode.keyboard,
                      subtitle: connected ? LocalizedStringKey(IBLocale.MenuBar.keyboardSubtitle)
                                         : LocalizedStringKey(IBLocale.Status.connectIPhoneFirst),
                      isOn: featureBinding(.keyboard, \.keyboardOn),
                      isEnabled: connected)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            sectionHeader(LocalizedStringKey(IBLocale.MenuBar.actionsSection))
            ActionRow(icon: "rectangle.on.rectangle",
                      title: LocalizedStringKey(IBLocale.MenuBar.openControlPanel),
                      shortcut: "⌘P",
                      help: LocalizedStringKey(IBLocale.MenuBar.openControlPanelHelp),
                      action: { openWindowActivating(id: "controls") },
                      keys: KeyboardShortcut("p"))
            ActionRow(icon: "macwindow",
                      title: LocalizedStringKey(IBLocale.MenuBar.openPreviewWindow),
                      shortcut: "⌘⇧P",
                      help: LocalizedStringKey(IBLocale.MenuBar.openPreviewWindowHelp),
                      action: { openWindowActivating(id: "preview") },
                      keys: KeyboardShortcut("p", modifiers: [.command, .shift]))
            ActionRow(icon: "checklist",
                      title: LocalizedStringKey(IBLocale.A11y.connectionTest),
                      shortcut: "⌘T",
                      help: LocalizedStringKey(IBLocale.MenuBar.connectionTestHelp),
                      action: { openWindowActivating(id: "test") },
                      keys: KeyboardShortcut("t"))
            ActionRow(icon: "arrow.triangle.2.circlepath.camera",
                      title: LocalizedStringKey(IBLocale.A11y.switchCamera),
                      shortcut: "",
                      help: LocalizedStringKey(IBLocale.A11y.switchCameraHint),
                      action: { session.toggleCamera() })
            ActionRow(icon: session.isRecording ? "stop.circle.fill" : "record.circle",
                      title: LocalizedStringKey(session.isRecording
                                                ? IBLocale.Record.stop
                                                : IBLocale.Record.start),
                      shortcut: "⌘R",
                      help: LocalizedStringKey(IBLocale.Record.help),
                      action: { session.toggleRecording() },
                      keys: KeyboardShortcut("r"))
            ActionRow(icon: "doc.on.clipboard",
                      title: LocalizedStringKey(IBLocale.Transfer.clipboardToiPhone),
                      shortcut: "",
                      help: LocalizedStringKey(IBLocale.Transfer.clipboardHelp),
                      action: { session.sendClipboardToPhone() })
            if let file = session.lastReceivedFileURL {
                ActionRow(icon: "folder",
                          title: LocalizedStringKey(IBLocale.Transfer.showInFinder),
                          shortcut: "",
                          help: LocalizedStringKey(IBLocale.Transfer.lastReceived),
                          action: { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            }
            ActionRow(icon: "cable.connector",
                      title: LocalizedStringKey(IBLocale.Connection.connectManually),
                      shortcut: "",
                      help: LocalizedStringKey(IBLocale.Connection.manualHint),
                      action: { showManualConnect = true })
            if session.state.phoneName != nil {
                ActionRow(icon: "xmark.circle",
                          title: LocalizedStringKey(IBLocale.Connection.disconnect),
                          shortcut: "",
                          help: LocalizedStringKey(IBLocale.Connection.disconnect),
                          action: { session.disconnect() })
            }
            ActionRow(icon: "gear",
                      title: LocalizedStringKey(IBLocale.MenuBar.preferences),
                      shortcut: "⌘,",
                      help: LocalizedStringKey(IBLocale.MenuBar.preferencesHelp),
                      action: { openPreferences() },
                      keys: KeyboardShortcut(","))
            ActionRow(icon: "power",
                      title: LocalizedStringKey(IBLocale.App.quit),
                      shortcut: "⌘Q",
                      help: LocalizedStringKey(IBLocale.App.quit),
                      action: { NSApplication.shared.terminate(nil) },
                      keys: KeyboardShortcut("q"))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("RemoteCrab v\(appVersion)")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.secondary)
                .ibEyebrowTracking()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2"
    }

    // MARK: - Helpers

    /// Opens a window scene and brings the (LSUIElement) app forward so
    /// the window doesn't land behind whatever app is currently active.
    private func openWindowActivating(id: String) {
        openWindow(id: id)
        NSApp.activate()
    }

    /// The Settings scene has no `openWindow(id:)`; it opens through
    /// the responder chain instead.
    private func openPreferences() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
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
    /// frame. Until the first snapshot arrives the toggle is disabled
    /// (writes would be silently dropped by `ReceiverSession`).
    private func featureBinding(
        _ feature: IBFeature,
        _ keyPath: KeyPath<FeatureStateSnapshot, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { session.featureState?[keyPath: keyPath] ?? false },
            set: { session.setFeature(feature, $0) }
        )
    }

    // Status derived from the live session state. The pill itself is
    // `IBStatusPill` (see `ReceiverSession.State.statusPillStatus`);
    // this color is only reused for the latency readout in deviceRow.
    private var statusColor: Color {
        switch session.state {
        case .searching:        return IBColor.warning
        case .connecting:       return IBColor.warning
        case .handshaking:      return IBColor.warning
        case .awaitingApproval: return IBColor.warning
        case .streaming:        return IBColor.success
        case .error:            return IBColor.error
        }
    }
}

// MARK: - Toggle row

private struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: LocalizedStringKey
    @Binding var isOn: Bool
    var isEnabled: Bool = true

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
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!isEnabled)
                // The visible label is hidden from the switch itself,
                // so without this VoiceOver only reads "switch, off".
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - Action row

private struct ActionRow: View {
    let icon: String
    let title: LocalizedStringKey
    let shortcut: String
    let help: LocalizedStringKey
    let action: () -> Void
    var keys: KeyboardShortcut? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
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
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                    .padding(.horizontal, 6)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(keys)
        .help(Text(help))
        .onHover { isHovering = $0 }
    }
}
