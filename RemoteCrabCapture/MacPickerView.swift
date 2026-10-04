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
                if let gaveUp = engine.preferredGaveUp {
                    gaveUpSection(gaveUp)
                }
                if let preferred = engine.preferredMac {
                    preferredSection(preferred)
                }
                if engine.connectedMacName != nil || engine.pendingMacName != nil {
                    sessionSection
                }
                seenSection
            }
            .navigationTitle(Text(IBLocale.Pairing.macPickerTitle))
            .task {
                // Wait out the preference's grace period so the "gave up"
                // line appears on time. Without this the lapse is only
                // noticed when something else triggers a refresh, and a
                // phone sitting open on this screen would keep claiming it
                // is waiting.
                if let armed = engine.preferredArmedAt {
                    let remaining = MacPairingStore.preferredGrace
                        - Date().timeIntervalSince(armed)
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    engine.recheckPreferredMac()
                }
                // Opening the picker is the moment stale rows are visible,
                // so it is also the moment to drop them: superseded
                // identities (a receiver that changed id) and machines gone
                // for months. Without this the list only ever shrinks when
                // the next connection happens to knock, and a phone that
                // accumulated duplicates keeps showing them.
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
                Label {
                    Text(IBLocale.Pairing.waitingForPreferred(preferred.name))
                        .font(IBFont.bodyMedium)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.accentColor)
                }
                // WHY, not just advice. A denied computer will never retry on
                // its own; a busy one retries every 15 s and needs nothing.
                // Saying which one this is the difference between waiting and
                // walking to another machine.
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
        case .streaming, .none: return IBLocale.Pairing.waitingReasonNotSeenYet
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

    /// Every computer seen on the network. Paired ones show a shield;
    /// brand-new ones are still tappable so first contact works even while
    /// another machine holds the session.
    ///
    /// Each row carries **what that computer's last attempt actually
    /// produced**, because the three cases look identical from the outside and
    /// need completely different things from the user:
    ///
    /// - "Found you, but <X> is using the iPhone" → a *switching* problem, and
    ///   the fix is right here: tap this row.
    /// - "Waiting for your approval" → the phone is holding a card they have
    ///   not answered yet.
    /// - "Hasn't connected yet" → the computer cannot even *see* this iPhone,
    ///   which is a network problem and tapping this row will not help.
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
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
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
                                Spacer(minLength: 8)
                                trailingBadge(for: computer, isConnected: isConnected)
                            }
                            statusLine(for: computer)
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

    /// The right-hand status pill. `streaming` is the only one that gets a
    /// colour; the rest are words, because a red badge on a machine that is
    /// merely waiting would cry wolf.
    @ViewBuilder
    private func trailingBadge(for computer: SeenComputer, isConnected: Bool) -> some View {
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

    /// The second line: what happened, and — for the case where tapping will
    /// not help — why.
    @ViewBuilder
    private func statusLine(for computer: SeenComputer) -> some View {
        switch computer.lastOutcome {
        case .streaming:
            EmptyView()
        case .waitingApproval:
            statusText(
                IBLocale.Pairing.Attempt.waitingApproval,
                stamp: computer.lastSeen,
                tint: Color.accentColor
            )
        case .refusedBusy(let owner):
            statusText(
                IBLocale.Pairing.Attempt.refusedBusy(owner: owner),
                stamp: computer.lastSeen,
                tint: .orange
            )
        case .denied:
            statusText(
                IBLocale.Pairing.Attempt.denied,
                stamp: computer.lastSeen,
                tint: .secondary
            )
        case nil:
            // Silence here is the diagnosis: this machine has never reached
            // this iPhone, so the problem is the network, not the pairing.
            Text(IBLocale.Pairing.Attempt.neverReached)
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
