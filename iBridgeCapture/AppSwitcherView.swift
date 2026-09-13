import SwiftUI
import iBridgeCore

/// iPhone-side Mac app switcher: lists the Mac's running apps and
/// brings the tapped one to the front. Pinned apps sort to the top.
/// Inspired by WhisPrompt's window wheel and the Codex Micro macropad's
/// "jump to the app that needs me" keys — but with no extra hardware.
struct AppSwitcherView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    @AppStorage("ibridge.ios.pinnedApps") private var pinnedCSV = ""

    private var pinned: Set<String> {
        Set(pinnedCSV.split(separator: ",").map(String.init))
    }

    private var sortedApps: [IBAppInfo] {
        let pins = pinned
        return engine.macApps.sorted { a, b in
            let pa = pins.contains(a.id), pb = pins.contains(b.id)
            if pa != pb { return pa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.macApps.isEmpty {
                    ContentUnavailableView {
                        Label(IBLocale.Switcher.empty, systemImage: "macwindow.on.rectangle")
                    }
                } else {
                    List {
                        ForEach(sortedApps) { app in
                            Button {
                                engine.activateMacApp(id: app.id)
                            } label: {
                                row(app)
                            }
                            .buttonStyle(.plain)
                            // Pin is reachable two ways so it isn't
                            // swipe-only (undiscoverable).
                            .swipeActions(edge: .trailing) {
                                pinButton(for: app, tint: .orange)
                            }
                            .contextMenu {
                                pinButton(for: app, tint: nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(IBLocale.Switcher.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { engine.requestMacApps() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(IBLocale.Switcher.refresh)

                    Button { engine.sendClipboard() } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .accessibilityLabel(IBLocale.Transfer.clipboardToMac)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.Settings.done) { dismiss() }
                }
            }
            .task { engine.requestMacApps() }
        }
    }

    private func row(_ app: IBAppInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pinned.contains(app.id) ? "pin.fill" : "app.dashed")
                .font(.system(size: 17))
                .foregroundStyle(pinned.contains(app.id) ? Color.accentColor : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                if app.isActive {
                    Text(IBLocale.Switcher.active)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if app.isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func pinButton(for app: IBAppInfo, tint: Color?) -> some View {
        Button { togglePin(app.id) } label: {
            Label(pinned.contains(app.id)
                  ? IBLocale.Switcher.unpin
                  : IBLocale.Switcher.pin,
                  systemImage: pinned.contains(app.id) ? "pin.slash" : "pin")
        }
        .tint(tint ?? .accentColor)
    }

    private func togglePin(_ id: String) {
        var set = pinned
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        pinnedCSV = set.sorted().joined(separator: ",")
    }
}
