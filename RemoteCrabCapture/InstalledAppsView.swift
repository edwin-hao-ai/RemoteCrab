import SwiftUI
import UIKit
import RemoteCrabCore

/// Dock-style launcher: every app the connected computer can open, as a
/// Launchpad-like grid of large icons — real app PNGs when the receiver
/// sends them, an initial tile otherwise. Search filters by name or
/// bundle id; tapping launches on the computer and dismisses.
struct InstalledAppsView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var icons: [String: UIImage] = [:]
    /// Set once the first reply has had time to arrive, so an empty result
    /// shows the empty state instead of an endless spinner.
    @State private var loaded = false

    /// Apps the user pinned to the top of the switcher float to the front
    /// here too (Stash's "hidden dock": the few you reach for, first).
    @AppStorage("remotecrab.ios.pinnedApps") private var pinnedCSV = ""

    private var apps: [IBInstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [IBInstalledApp]
        if needle.isEmpty {
            base = engine.installedApps
        } else {
            base = engine.installedApps.filter {
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
            Group {
                if apps.isEmpty && !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if apps.isEmpty {
                    ContentUnavailableView {
                        Label(IBLocale.Launcher.empty, systemImage: "square.grid.2x2")
                    } description: {
                        Text(IBLocale.Launcher.hint)
                    }
                } else {
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
                }
            }
            .navigationTitle(IBLocale.Launcher.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: IBLocale.Launcher.searchPlaceholder)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.A11y.close) { dismiss() }
                }
            }
        }
        .onAppear { rebuildIcons(engine.installedApps) }
        .onChange(of: engine.installedApps) { _, list in rebuildIcons(list) }
        .task {
            engine.requestInstalledApps()
            // The receiver enumerates + rasterises icons; give it a beat
            // before deciding the list is genuinely empty.
            try? await Task.sleep(for: .milliseconds(500))
            loaded = true
        }
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

    /// Decode each icon PNG once per list update rather than per render.
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
