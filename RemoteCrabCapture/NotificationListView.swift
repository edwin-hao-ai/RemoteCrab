import RemoteCrabCore
import SwiftUI

/// Sheet showing the notifications relayed from the Mac (newest first).
/// Opening it marks everything read; "Clear" empties the inbox.
struct NotificationListView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    private var store: NotificationStore { engine.notificationStore }

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            // Tapping a row does exactly what tapping the
                            // system banner does: switch the Mac to the app
                            // that sent it.
                            Button {
                                engine.activateRelayedApp(named: entry.notification.app,
                                                          windowTitle: entry.notification.windowTitle)
                                dismiss()
                            } label: {
                                row(entry.notification, at: entry.receivedAt)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(IBLocale.Notify.section)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.entries.isEmpty {
                        Button(IBLocale.Notify.clear) { store.clear() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IBLocale.Settings.done) { dismiss() }
                }
            }
        }
        .onAppear {
            store.markAllRead()
            // Screenshot runs must not drop the system permission alert over
            // the very inbox they are capturing.
            guard ProcessInfo.processInfo.environment["REMOTECRAB_E2E_NO_NOTIFY_PROMPT"] != "1" else { return }
            // Ask for banner permission here, in context — never at boot,
            // where the system alert would block the E2E bootstrap.
            Task { await engine.requestNotificationAuthorization() }
        }
    }

    private func row(_ n: IBNotification, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(n.app)
                    .font(IBFont.caption.weight(.semibold))
                    .foregroundStyle(IBColor.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(date, style: .relative)
                    .font(IBFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(n.title)
                .font(IBFont.bodyMedium.weight(.semibold))
                .foregroundStyle(.primary)
            if !n.subtitle.isEmpty {
                Text(n.subtitle)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !n.body.isEmpty {
                Text(n.body)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: IBSpace.l.pt) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(IBLocale.Notify.empty)
                .font(IBFont.bodyMedium)
                .foregroundStyle(.secondary)
            Text(IBLocale.Notify.emptyHint)
                .font(IBFont.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IBSpace.xl.pt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
