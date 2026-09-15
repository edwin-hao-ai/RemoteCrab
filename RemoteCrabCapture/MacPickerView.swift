import SwiftUI
import RemoteCrabCore

/// Pick which Mac this iPhone serves when several are on the network.
///
/// The iPhone is the TCP server, so "switching Mac" means: arm a
/// preference for the chosen Mac, drop the current owner, and answer
/// every other Mac "busy" until the chosen one reconnects (or the
/// preference expires). The chosen Mac takes over on its next connect —
/// automatically, or after the user clicks Retry in its menu bar.
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
                pairedSection
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

    /// Banner while a switch is armed: who we're waiting for + a way
    /// to give up and let any Mac pair normally again.
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

    /// The live session: current owner (with disconnect) and a Mac
    /// waiting for approval (with allow / deny).
    private var sessionSection: some View {
        Section {
            if let connected = engine.connectedMacName {
                HStack {
                    Label(connected, systemImage: "laptopcomputer")
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

    /// The allow-list. Tapping a row arms the switch; badges show who
    /// is connected right now.
    private var pairedSection: some View {
        Section {
            if engine.pairedMacs.isEmpty {
                Text(IBLocale.Pairing.nonePaired)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.pairedMacs) { mac in
                    let isConnected = engine.connectedMacId == mac.id
                    Button {
                        engine.setPreferredMac(id: mac.id)
                    } label: {
                        HStack {
                            Image(systemName: "laptopcomputer")
                                .foregroundStyle(.secondary)
                            Text(mac.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if isConnected {
                                Text(IBLocale.Pairing.connectedNow)
                                    .font(IBFont.caption)
                                    .foregroundStyle(.green)
                            } else if engine.preferredMac?.id == mac.id {
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
            Text(IBLocale.Pairing.pairedMacs)
        } footer: {
            Text(IBLocale.Pairing.pickerFooter)
        }
    }
}
