import SwiftUI
import UIKit
import RemoteCrabCore

/// Full-screen Mac window picker: one large card per window (so the
/// snapshot is actually readable), newest first. Tap a card to switch and
/// dismiss; pull down to close. Before a window's snapshot arrives the
/// card shows that app's icon, so the layout never jumps.
///
/// Everything secondary (pin, quit, force quit) lives in the long-press
/// menu — the surface itself has no buttons.
struct AppSwitcherView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    @AppStorage("remotecrab.ios.pinnedApps") private var pinnedCSV = ""

    /// The window whose app is awaiting a destructive force-quit confirm.
    @State private var forceQuitTarget: IBWindowInfo?
    /// The installed-app launcher sheet.
    @State private var showLauncher = false

    private var pinned: Set<String> {
        Set(pinnedCSV.split(separator: ",").map(String.init))
    }

    /// Pinned apps first (preserving the Mac's front-to-back order within
    /// each group).
    private var orderedWindows: [IBWindowInfo] {
        guard !pinned.isEmpty else { return engine.macWindows }
        return engine.macWindows.filter { pinned.contains($0.appId) }
             + engine.macWindows.filter { !pinned.contains($0.appId) }
    }

    private var forceQuitPresented: Binding<Bool> {
        Binding(
            get: { forceQuitTarget != nil },
            set: { if !$0 { forceQuitTarget = nil } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Quick destinations: reveal the desktop, or open the launcher.
            HStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    engine.sendSystemCommand(IBSystemCommand(command: .showDesktop))
                } label: {
                    Label(IBLocale.Switcher.desktop, systemImage: "menubars.rectangle")
                        .font(IBFont.bodySmall)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(IBPressButtonStyle(scale: 0.97, highlight: 0.06))

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showLauncher = true
                } label: {
                    Label(IBLocale.Switcher.launchApps, systemImage: "square.grid.2x2")
                        .font(IBFont.bodySmall)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(IBPressButtonStyle(scale: 0.97, highlight: 0.06))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .sheet(isPresented: $showLauncher) {
                InstalledAppsView()
                    .environmentObject(engine)
            }

            if !engine.windowsCanCapture && !engine.macWindows.isEmpty {
                permissionHint
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            if orderedWindows.isEmpty {
                ContentUnavailableView {
                    Label(IBLocale.Switcher.empty, systemImage: "macwindow.on.rectangle")
                } description: {
                    Text(IBLocale.Switcher.hint)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(orderedWindows) { window in
                            card(window)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task {
            engine.requestMacApps()
            engine.requestMacWindows()
        }
        .confirmationDialog(
            IBLocale.Switcher.forceQuitConfirmTitle,
            isPresented: forceQuitPresented,
            titleVisibility: .visible,
            presenting: forceQuitTarget
        ) { window in
            Button(IBLocale.Switcher.forceQuit, role: .destructive) {
                engine.quitMacApp(id: window.appId, force: true)
            }
            Button(IBLocale.Connection.cancel, role: .cancel) {}
        } message: { _ in
            Text(IBLocale.Switcher.forceQuitConfirmMessage)
        }
    }

    @ViewBuilder
    private func card(_ window: IBWindowInfo) -> some View {
        Button {
            engine.activateMacApp(id: window.appId,
                                  windowTitle: window.title.isEmpty ? nil : window.title)
            dismiss()
        } label: {
            cardBody(window)
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.97, highlight: 0.06))
        .contextMenu {
            Button {
                togglePin(window.appId)
            } label: {
                Label(pinned.contains(window.appId) ? IBLocale.Switcher.unpin : IBLocale.Switcher.pin,
                      systemImage: pinned.contains(window.appId) ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                engine.quitMacApp(id: window.appId, force: false)
            } label: {
                Label(IBLocale.Switcher.quit, systemImage: "power")
            }
            Button(role: .destructive) {
                forceQuitTarget = window
            } label: {
                Label(IBLocale.Switcher.forceQuit, systemImage: "bolt.fill")
            }
        }
        .accessibilityLabel(Text(window.title.isEmpty ? window.appName : "\(window.appName), \(window.title)"))
        .accessibilityAddTraits(.isButton)
    }

    private func cardBody(_ window: IBWindowInfo) -> some View {
        VStack(spacing: 0) {
            shot(window)
            meta(window)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(window.isActive ? IBColor.accent : IBColor.borderSubtle,
                        lineWidth: window.isActive ? 2 : 1)
        }
    }

    private func shot(_ window: IBWindowInfo) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let image = engine.macWindowSnapshots[window.id] {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                VStack(spacing: IBSpace.m.pt) {
                    AppIconTile(image: engine.macAppIcons[window.appId],
                                name: window.appName, size: 56)
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(IBFont.bodySmall)
                        .foregroundStyle(IBColor.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, IBSpace.l.pt)
                }
            }
        }
        .aspectRatio(aspect(window), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func meta(_ window: IBWindowInfo) -> some View {
        HStack(spacing: IBSpace.s.pt) {
            AppIconTile(image: engine.macAppIcons[window.appId], name: window.appName, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(window.appName)
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(IBColor.textPrimary)
                    .lineLimit(1)
                if !window.title.isEmpty {
                    Text(window.title)
                        .font(IBFont.caption)
                        .foregroundStyle(IBColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: IBSpace.s.pt)
            if window.isActive {
                activeBadge
            }
        }
        .padding(.horizontal, IBSpace.m.pt)
        .padding(.vertical, IBSpace.s.pt)
    }

    private var activeBadge: some View {
        Text(IBLocale.Switcher.active)
            .font(IBFont.eyebrowMono)
            .ibEyebrowTracking()
            .foregroundStyle(IBColor.accent)
            .lineLimit(1)
            .padding(.horizontal, IBSpace.s.pt)
            .padding(.vertical, 3)
            .background(IBColor.accent.opacity(0.12), in: Capsule())
            .accessibilityHidden(true)
    }

    private var permissionHint: some View {
        HStack(spacing: IBSpace.s.pt) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(IBLocale.Switcher.permissionHint)
                .font(IBFont.bodySmall)
                .foregroundStyle(IBColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(IBSpace.m.pt)
        .background(Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous))
    }

    /// Window content aspect, falling back to a 16:10 card when the Mac
    /// didn't report a size (app-level entries / no permission).
    private func aspect(_ window: IBWindowInfo) -> CGFloat {
        guard window.width > 0, window.height > 0 else { return 16.0 / 10.0 }
        return CGFloat(window.width / window.height)
    }

    private func togglePin(_ appId: String) {
        var set = pinned
        if set.contains(appId) { set.remove(appId) } else { set.insert(appId) }
        pinnedCSV = set.sorted().joined(separator: ",")
    }
}

/// A Mac app's icon, falling back to a tinted initial tile while the icon
/// PNG is still in flight (or when the app has a generic icon).
private struct AppIconTile: View {
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

/// Pressed-state feedback now lives in `IBPressButtonStyle` (RemoteCrabCore).
