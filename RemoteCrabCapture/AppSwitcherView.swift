import SwiftUI
import UIKit
import RemoteCrabCore

/// iPhone-side Mac app switcher: lists the Mac's running apps with their
/// real icons, pinned apps first, and brings the tapped one to the front.
/// A deliberate left-swipe (or the long-press menu) quits an app;
/// force-quitting is destructive and always confirmed.
///
/// Inspired by WhisPrompt's window wheel and the Codex Micro macropad's
/// "jump to the app that needs me" keys — but with no extra hardware.
struct AppSwitcherView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    @AppStorage("remotecrab.ios.pinnedApps") private var pinnedCSV = ""

    /// The app awaiting a destructive force-quit confirmation.
    @State private var forceQuitTarget: IBAppInfo?
    /// Non-nil while the "maybe waiting on a save sheet" hint is shown.
    @State private var quitHint: String?

    private var pinned: Set<String> {
        Set(pinnedCSV.split(separator: ",").map(String.init))
    }

    private var pinnedApps: [IBAppInfo] {
        engine.macApps
            .filter { pinned.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var unpinnedApps: [IBAppInfo] {
        engine.macApps
            .filter { !pinned.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var forceQuitPresented: Binding<Bool> {
        Binding(
            get: { forceQuitTarget != nil },
            set: { if !$0 { forceQuitTarget = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.macApps.isEmpty {
                    ContentUnavailableView {
                        Label(IBLocale.Switcher.empty, systemImage: "macwindow.on.rectangle")
                    } description: {
                        Text(IBLocale.Switcher.hint)
                    }
                } else {
                    list
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
            .overlay(alignment: .bottom) { hintBanner }
            .confirmationDialog(
                IBLocale.Switcher.forceQuitConfirmTitle,
                isPresented: forceQuitPresented,
                titleVisibility: .visible,
                presenting: forceQuitTarget
            ) { app in
                Button(IBLocale.Switcher.forceQuit, role: .destructive) {
                    performQuit(app, force: true)
                }
                Button(IBLocale.Connection.cancel, role: .cancel) {}
            } message: { _ in
                Text(IBLocale.Switcher.forceQuitConfirmMessage)
            }
        }
    }

    private var list: some View {
        List {
            if !pinnedApps.isEmpty {
                Section {
                    ForEach(pinnedApps) { row(for: $0) }
                } header: {
                    header(IBLocale.Switcher.pinnedSection)
                }
            }
            Section {
                ForEach(unpinnedApps) { row(for: $0) }
            } header: {
                header(IBLocale.Switcher.allAppsSection)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func row(for app: IBAppInfo) -> some View {
        Button {
            engine.activateMacApp(id: app.id)
        } label: {
            rowContent(app)
        }
        .buttonStyle(.plain)
        // Destructive actions go trailing (left-swipe) and never trigger
        // on a full swipe — quitting should be deliberate.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                performQuit(app, force: false)
            } label: {
                Label(IBLocale.Switcher.quit, systemImage: "power")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                togglePin(app.id)
            } label: {
                Label(pinned.contains(app.id) ? IBLocale.Switcher.unpin : IBLocale.Switcher.pin,
                      systemImage: pinned.contains(app.id) ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                togglePin(app.id)
            } label: {
                Label(pinned.contains(app.id) ? IBLocale.Switcher.unpin : IBLocale.Switcher.pin,
                      systemImage: pinned.contains(app.id) ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                performQuit(app, force: false)
            } label: {
                Label(IBLocale.Switcher.quit, systemImage: "power")
            }
            Button(role: .destructive) {
                forceQuitTarget = app
            } label: {
                Label(IBLocale.Switcher.forceQuit, systemImage: "bolt.fill")
            }
        }
    }

    private func rowContent(_ app: IBAppInfo) -> some View {
        HStack(spacing: IBSpace.m.pt) {
            AppIconView(image: engine.macAppIcons[app.id], name: app.name)
                .frame(width: 40, height: 40)

            Text(app.name)
                .font(IBFont.bodyLarge)
                .foregroundStyle(IBColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: IBSpace.s.pt)

            if app.isActive {
                activeBadge
            } else if pinned.contains(app.id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(IBColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, IBSpace.xxs.pt)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(app.isActive ? IBLocale.Switcher.active : "")
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

    private func header(_ text: String) -> some View {
        Text(text)
            .font(IBFont.eyebrowMono)
            .ibEyebrowTracking()
            .foregroundStyle(IBColor.textSecondary)
    }

    @ViewBuilder
    private var hintBanner: some View {
        if let quitHint {
            Text(quitHint)
                .font(IBFont.bodySmall)
                .foregroundStyle(IBColor.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IBSpace.l.pt)
                .padding(.vertical, IBSpace.m.pt)
                .background {
                    IBMaterial.bar(in: RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous)
                        .stroke(IBColor.borderRegular, lineWidth: 0.5)
                }
                .padding(.horizontal, IBSpace.l.pt)
                .padding(.bottom, IBSpace.l.pt)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func performQuit(_ app: IBAppInfo, force: Bool) {
        engine.quitMacApp(id: app.id, force: force)
        // A graceful quit can stall behind a save sheet on the Mac that
        // the iPhone can't see. Only then does the hint earn its place.
        guard !force else { return }
        let id = app.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard engine.macApps.contains(where: { $0.id == id }) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                quitHint = IBLocale.Switcher.quitStillRunning(app.name)
            }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeIn(duration: 0.2)) {
                quitHint = nil
            }
        }
    }

    private func togglePin(_ id: String) {
        var set = pinned
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        pinnedCSV = set.sorted().joined(separator: ",")
    }
}

/// A Mac app's icon. Falls back to a tinted initial tile while the icon
/// PNG is still in flight (background list refreshes don't carry icons)
/// so rows never flash a generic placeholder.
private struct AppIconView: View {
    let image: UIImage?
    let name: String

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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(IBColor.accent.opacity(0.14))
                    .overlay {
                        Text(initial)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(IBColor.accent)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(IBColor.borderSubtle, lineWidth: 0.5)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}
