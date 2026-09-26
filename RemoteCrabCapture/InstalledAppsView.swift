import SwiftUI
import UIKit
import RemoteCrabCore

/// The launch-able applications advertised by the connected computer
/// (`installedApps`, kind 0x21), searchable; tapping one launches it on the
/// computer via `systemCommand(.launchApp)`.
struct InstalledAppsView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var apps: [IBInstalledApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return engine.installedApps }
        return engine.installedApps.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IBSpace.s.pt) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(IBColor.textSecondary)
                TextField(IBLocale.Launcher.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, IBSpace.m.pt)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                )
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if apps.isEmpty {
                ContentUnavailableView {
                    Label(IBLocale.Launcher.empty, systemImage: "square.grid.2x2")
                } description: {
                    Text(IBLocale.Launcher.hint)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            row(app)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task {
            engine.requestInstalledApps()
        }
    }

    private func row(_ app: IBInstalledApp) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            engine.launchInstalledApp(app)
            dismiss()
        } label: {
            HStack(spacing: IBSpace.m.pt) {
                Text(String(app.name.first(where: { !$0.isWhitespace }).map(String.init) ?? "?"))
                    .font(IBFont.titleSmall)
                    .foregroundStyle(IBColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Color(uiColor: .tertiarySystemFill))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(IBFont.bodyMedium)
                        .foregroundStyle(IBColor.textPrimary)
                        .lineLimit(1)
                    Text(app.id)
                        .font(IBFont.caption)
                        .foregroundStyle(IBColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(IBColor.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.98, highlight: 0.04))
        .accessibilityLabel(Text(app.name))
        .accessibilityAddTraits(.isButton)
    }
}
