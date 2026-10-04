import SwiftUI
import UIKit
import RemoteCrabCore

/// Dock-style launcher: every app the connected computer can open, as a
/// Launchpad-like grid of large icons — real app PNGs when the receiver
/// sends them, an initial tile otherwise. Search filters by name or
/// bundle id; tapping launches on the computer and dismisses.
///
/// The sheet shows four states, and only the receiver's `installedApps`
/// frame moves between them: waiting (spinner), a list, a list that is
/// genuinely empty, and nobody answering at all. It used to time-box the
/// wait at 500 ms and treat the timeout as "no apps" — while the Mac needs
/// ~2.4 s to answer — so the empty state flashed under every first open.
struct InstalledAppsView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var icons: [String: UIImage] = [:]

    /// Apps the user pinned to the top of the switcher float to the front
    /// here too (Stash's "hidden dock": the few you reach for, first).
    @AppStorage("remotecrab.ios.pinnedApps") private var pinnedCSV = ""

    private var isLinked: Bool { engine.connectionState == .connected }

    private var apps: [IBInstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [IBInstalledApp]
        if needle.isEmpty {
            base = engine.peer.installedApps
        } else {
            base = engine.peer.installedApps.filter {
                $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
            }
        }
        let pinned = Set(pinnedCSV.split(separator: ",").map(String.init))
        guard !pinned.isEmpty else { return base }
        return base.filter { pinned.contains($0.id) } + base.filter { !pinned.contains($0.id) }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 78, maximum: 104), spacing: IBSpace.l.pt)
    ]

    var body: some View {
        NavigationStack {
            state
                .navigationTitle(IBLocale.Launcher.title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: IBLocale.Launcher.searchPlaceholder)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.A11y.close) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        engine.requestInstalledApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!isLinked)
                    .accessibilityLabel(Text(IBLocale.Switcher.refresh))
                }
            }
        }
        .onAppear { rebuildIcons(engine.peer.installedApps) }
        .onChange(of: engine.peer.installedApps) { _, list in rebuildIcons(list) }
        .task { engine.requestInstalledApps() }
        .onChange(of: engine.connectionState) { _, state in
            // The sheet is reachable before the Mac is: it can be opened
            // from the switcher the instant the app launches, while the
            // handshake is still running. `.task` fires once, so without
            // this the sheet sat on "not connected" for as long as the
            // handshake took — measured at 8 s on a real session — and
            // needed a manual refresh for a link that had already come up.
            if state == .connected, engine.peer.installedApps.isEmpty {
                engine.requestInstalledApps()
            }
        }
    }

    /// Only the receiver's frame moves between these. `awaiting` is the only
    /// state that may show a spinner, and `answered` the only one that may
    /// show an empty list.
    @ViewBuilder
    private var state: some View {
        if !apps.isEmpty {
            // A list we already have is shown immediately, even while a
            // refresh is in flight — replacing it with a spinner would throw
            // away something the user can act on.
            grid
        } else if !isLinked {
            unavailable(IBLocale.Error.notConnectedToMac,
                        hint: IBLocale.Launcher.offlineHint)
        } else if engine.installedAppsPhase == .awaiting {
            loading
        } else if engine.installedAppsPhase == .unanswered {
            // The receiver sends 0x21 only in answer to 0x20, so silence is a
            // dead link or a receiver too old to know the frame — never
            // "this computer has no apps".
            unavailable(IBLocale.Launcher.noAnswer, hint: IBLocale.Launcher.noAnswerHint)
        } else {
            ContentUnavailableView {
                Label(IBLocale.Launcher.empty, systemImage: "square.grid.2x2")
            } description: {
                Text(IBLocale.Launcher.hint)
            }
        }
    }

    /// The Mac's list is on the way — say so, and change nothing yet.
    private var loading: some View {
        VStack(spacing: IBSpace.m.pt) {
            ProgressView()
            Text(IBLocale.Launcher.loading)
                .font(IBFont.bodySmall)
                .foregroundStyle(IBColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(IBLocale.Launcher.loading))
    }

    /// Not a result — a state the user can leave. Both the title and the
    /// hint have to hold up: the title says what happened, the hint says
    /// what to do about it.
    private func unavailable(_ title: String, hint: String) -> some View {
        VStack(spacing: IBSpace.m.pt) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 34))
                .foregroundStyle(IBColor.textSecondary)
            Text(title)
                .font(IBFont.bodyMedium)
                .foregroundStyle(IBColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(hint)
                .font(IBFont.bodySmall)
                .foregroundStyle(IBColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                engine.requestInstalledApps()
            } label: {
                Text(IBLocale.Switcher.refresh)
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .padding(.horizontal, IBSpace.l.pt)
                    .frame(height: 44)          // ≥ 44 pt target, per the a11y pass
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(IBPressButtonStyle())
            .disabled(!isLinked)
        }
        .padding(IBSpace.l.pt)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center,
                      spacing: IBSpace.l.pt) {
                ForEach(apps) { app in
                    tile(app)
                }
            }
            .padding(.horizontal, IBSpace.l.pt)
            .padding(.vertical, IBSpace.l.pt)
        }
        .refreshable { engine.requestInstalledApps() }
    }

    /// One Launchpad tile: 64 pt icon with the name beneath.
    private func tile(_ app: IBInstalledApp) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            engine.launchInstalledApp(app)
            dismiss()
        } label: {
            VStack(spacing: IBSpace.s.pt) {
                AppIconTile(image: icons[app.id], name: app.name, size: 64)
                Text(app.name)
                    .font(IBFont.caption)
                    .foregroundStyle(IBColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.94))
        .accessibilityLabel(Text(app.name))
        .accessibilityAddTraits(.isButton)
    }

    /// Decode each icon once per list update rather than per render.
    private func rebuildIcons(_ list: [IBInstalledApp]) {
        var decoded: [String: UIImage] = [:]
        for app in list {
            if let data = app.iconPNG, let image = UIImage(data: data) {
                decoded[app.id] = image
            }
        }
        icons = decoded
    }
}
