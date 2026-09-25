import SwiftUI
import RemoteCrabCore

/// Pick which computer (Mac **or** Windows PC) this iPhone serves.
///
/// The iPhone is the TCP server, so "switching" means: arm a preference for
/// the chosen computer, drop the current owner, and answer every other one
/// "in use" until the chosen one reconnects (or the preference expires). The
/// chosen computer takes over on its next connect — automatically, or after
/// the user clicks Retry in its menu.
///
/// The list is **every computer we've seen** (`seenComputers`), not just the
/// paired ones — otherwise a brand-new Windows PC could never be selected
/// while a Mac held the session, which is the exact dead-end users hit.
struct MacPickerView: View {
    @EnvironmentObject var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let preferred = engine.preferredMac {
                    preferredSection(preferred)
                }
                if engine.connectedMacName != nil || engine.pendingMacName != nil {
                    sessionSection
                }
                seenSection
            }
            .navigationTitle(Text(IBLocale.Pairing.macPickerTitle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text(IBLocale.Settings.done)
                    }
                    .accessibilityLabel(IBLocale.Settings.done)
                }
            }
        }
    }

    /// Banner while a switch is armed: who we're waiting for + a way to
    /// give up and let any computer pair normally again.
    private func preferredSection(_ preferred: PairedMac) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(IBLocale.Pairing.waitingForPreferred(preferred.name))
                        .font(IBFont.bodyMedium)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.accentColor)
                }
                Button(IBLocale.Pairing.cancelPreferred, role: .destructive) {
                    engine.clearPreferredMac()
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    /// The live session: current owner (with disconnect) and a computer
    /// waiting for approval (with allow / deny).
    private var sessionSection: some View {
        Section {
            if let connected = engine.connectedMacName {
                HStack {
                    computerIcon(for: connected, platform: engine.connectedPlatform)
                    Spacer()
                    Text(IBLocale.Pairing.connectedNow)
                        .font(IBFont.caption)
                        .foregroundStyle(.secondary)
                    Button(IBLocale.Pairing.disconnect, role: .destructive) {
                        engine.disconnectCurrentMac()
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let pending = engine.pendingMacName {
                HStack {
                    Label(pending, systemImage: "laptopcomputer")
                    Spacer()
                    Button(IBLocale.Pairing.allow) {
                        engine.approvePendingMac()
                    }
                    .buttonStyle(.borderless)
                    Button(IBLocale.Pairing.deny, role: .destructive) {
                        engine.denyPendingMac()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Every computer seen on the network. Paired ones show a shield;
    /// brand-new ones are still tappable so first contact works even while
    /// another machine holds the session.
    private var seenSection: some View {
        Section {
            if engine.seenComputers.isEmpty {
                Text(IBLocale.Pairing.nonePaired)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.seenComputers.filter {
                    $0.id != engine.connectedMacId && $0.name != engine.pendingMacName
                }) { computer in
                    let isConnected = engine.connectedMacId == computer.id
                    let isPaired = engine.pairedMacs.contains { $0.id == computer.id }
                    Button {
                        engine.setPreferredComputer(id: computer.id)
                    } label: {
                        HStack {
                            computerIcon(for: computer.name, platform: computer.platform)
                            if !isPaired {
                                Text(IBLocale.Pairing.notPairedBadge)
                                    .font(IBFont.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background {
                                        Capsule().fill(Color.accentColor.opacity(0.15))
                                    }
                            }
                            Spacer()
                            if isConnected {
                                Text(IBLocale.Pairing.connectedNow)
                                    .font(IBFont.caption)
                                    .foregroundStyle(.green)
                            } else if engine.preferredMac?.id == computer.id {
                                Text(IBLocale.Pairing.waitingBadge)
                                    .font(IBFont.caption)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(IBFont.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .disabled(isConnected)
                }
            }
        } header: {
            Text(IBLocale.Pairing.seenComputers)
        } footer: {
            Text(IBLocale.Pairing.pickerFooter)
        }
    }

    /// A platform-appropriate glyph + name, so a user with both a Mac and a
    /// PC on the network can tell them apart at a glance.
    private func computerIcon(for name: String, platform: String) -> some View {
        let isWindows = platform.lowercased() == "windows"
        return Label {
            Text(name).foregroundStyle(.primary)
        } icon: {
            Image(systemName: isWindows ? "pc" : "laptopcomputer")
                .foregroundStyle(.secondary)
        }
    }
}
