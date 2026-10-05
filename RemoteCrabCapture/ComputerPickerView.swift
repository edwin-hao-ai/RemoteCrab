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
/// The list is the **roster**: every computer we have seen, with the ones
/// announcing themselves right now marked **Online** and sorted first. That is
/// the thing the old list could not tell the user — a row for a computer that
/// is switched off looked exactly like a row for the one in the next room.
struct ComputerPickerView: View {
    @EnvironmentObject var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    private var roster: [ComputerRosterEntry] {
        ComputerRoster.entries(online: engine.onlineComputers, seen: engine.seenComputers)
    }

    var body: some View {
        NavigationStack {
            List {
                if let gaveUp = engine.preferredGaveUp {
                    gaveUpSection(gaveUp)
                }
                if let preferred = engine.preferredMac {
                    preferredSection(preferred)
                }
                if engine.connectedMacName != nil || engine.pendingMacName != nil {
                    sessionSection
                }
                rosterSection
            }
            .navigationTitle(Text(IBLocale.Pairing.macPickerTitle))
            .task {
                if let armed = engine.preferredArmedAt {
                    let remaining = MacPairingStore.preferredGrace
                        - Date().timeIntervalSince(armed)
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    engine.recheckPreferredMac()
                }
                engine.pruneSeenComputers()
            }
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
                if engine.onlineComputers.contains(where: { $0.id == preferred.id }) {
                    // The computer is on the network, so this is a short wait —
                    // show the mascot rather than a bare clock.
                    HStack(spacing: IBSpace.m.pt) {
                        CrabLoading(message: LocalizedStringKey(IBLocale.Pairing.switchingTo(preferred.name)),
                                    size: 56)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label {
                        Text(IBLocale.Pairing.waitingForPreferred(preferred.name))
                            .font(IBFont.bodyMedium)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                // WHY, not just advice. A denied computer will never retry on
                // its own; a busy one retries every 15 s and needs nothing.
                Text(reason(for: preferred))
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
                Text(IBLocale.Pairing.preferredGraceWindow)
                    .font(IBFont.caption)
                    .foregroundStyle(.tertiary)
                Button(IBLocale.Pairing.cancelPreferred, role: .destructive) {
                    engine.clearPreferredMac()
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    /// The chosen computer's last recorded attempt, turned into one line that
    /// says what is happening and what to do about it.
    private func reason(for preferred: PairedMac) -> String {
        switch engine.preferredOutcome(for: preferred.id) {
        case .denied: return IBLocale.Pairing.waitingReasonDenied(preferred.name)
        case .refusedBusy: return IBLocale.Pairing.waitingReasonBusy(preferred.name)
        case .waitingApproval: return IBLocale.Pairing.waitingReasonApproval(preferred.name)
        case .streaming, .none:
            return engine.onlineComputers.contains(where: { $0.id == preferred.id })
                ? IBLocale.Pairing.waitingReasonApproval(preferred.name)
                : IBLocale.Pairing.waitingReasonNotSeenYet
        }
    }

    /// Once, after the grace is spent. Without it the waiting banner would
    /// just vanish, which reads as a bug rather than as a decision.
    private func gaveUpSection(_ gaveUp: PairedMac) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "door.left.hand.open")
                    .foregroundStyle(IBColor.textSecondary)
                Text(IBLocale.Pairing.preferredGaveUp(gaveUp.name))
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(IBLocale.Settings.done) { engine.clearPreferredGaveUp() }
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
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

    /// Every computer, online first. A green dot marks one announcing itself
    /// now; a grey "Offline · last seen …" line marks one that is known but
    /// not here. Tapping an online computer connects within about a second;
    /// tapping an offline one is still allowed and says it will connect when
    /// the computer returns.
    private var rosterSection: some View {
        Section {
            if roster.isEmpty {
                Text(IBLocale.Pairing.nonePaired)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                // The connected computer is already shown above with its
                // Disconnect control; listing it again here was a duplicate row.
                ForEach(roster.filter { $0.id != engine.connectedMacId }) { entry in
                    let isConnected = engine.connectedMacId == entry.id
                    let isPaired = engine.pairedMacs.contains { $0.id == entry.id }
                    let seen = engine.seenComputers.first { $0.id == entry.id }
                    Button {
                        engine.setPreferredComputer(id: entry.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                computerIcon(for: entry.name, platform: entry.platform)
                                if entry.isOnline { onlineDot }
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
                                Spacer(minLength: 8)
                                trailingBadge(for: entry, isConnected: isConnected)
                            }
                            statusLine(for: entry, seen: seen)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnected)
                }
            }
        } header: {
            Text(IBLocale.Pairing.seenComputers)
        } footer: {
            Text(IBLocale.Pairing.pickerFooter)
        }
    }

    private var onlineDot: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Text(IBLocale.Pairing.online))
    }

    /// The right-hand status pill. `connected` is the only one that gets a
    /// colour; the rest are words, because a red badge on a machine that is
    /// merely waiting would cry wolf.
    @ViewBuilder
    private func trailingBadge(for entry: ComputerRosterEntry, isConnected: Bool) -> some View {
        if isConnected {
            Text(IBLocale.Pairing.connectedNow)
                .font(IBFont.caption)
                .foregroundStyle(.green)
        } else if engine.preferredMac?.id == entry.id {
            Text(IBLocale.Pairing.waitingBadge)
                .font(IBFont.caption)
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "chevron.right")
                .font(IBFont.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// The second line: presence, or — when the computer has actually knocked —
    /// what that attempt produced, because those cases need different actions
    /// from the user.
    @ViewBuilder
    private func statusLine(for entry: ComputerRosterEntry, seen: SeenComputer?) -> some View {
        if let seen, seen.lastOutcome != nil, !entry.isOnline {
            switch seen.lastOutcome {
            case .streaming:
                EmptyView()
            case .waitingApproval:
                statusText(IBLocale.Pairing.Attempt.waitingApproval, stamp: seen.lastSeen, tint: Color.accentColor)
            case .refusedBusy(let owner):
                statusText(IBLocale.Pairing.Attempt.refusedBusy(owner: owner), stamp: seen.lastSeen, tint: .orange)
            case .denied:
                statusText(IBLocale.Pairing.Attempt.denied, stamp: seen.lastSeen, tint: .secondary)
            case nil:
                EmptyView()
            }
        } else if entry.isOnline {
            Text(IBLocale.Pairing.online)
                .font(IBFont.caption)
                .foregroundStyle(.green)
                .accessibilityLabel(Text(IBLocale.Pairing.online))
        } else {
            (Text(IBLocale.Pairing.offline)
                + Text(verbatim: " · ")
                + Text(seen?.lastSeen ?? Date.distantPast, style: .relative))
                .font(IBFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(_ text: String, stamp: Date, tint: Color) -> some View {
        // `style: .relative` localises the "3 min ago" for free, in both
        // languages, and stays correct as time passes.
        (Text(text) + Text(verbatim: " · ") + Text(stamp, style: .relative))
            .font(IBFont.caption)
            .foregroundStyle(tint)
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
