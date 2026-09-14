import SwiftUI
import RemoteCrabCore

/// The main preview window — shows the most recently decoded H.264
/// frame from the iPhone. The decoder republishes each frame as a
/// `CGImage` on `ReceiverSession.latestFrame`, so display is a plain
/// SwiftUI `Image` with no re-encoding.
struct PreviewWindow: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let cgImage = session.latestFrame {
                Image(cgImage, scale: 1, label: Text("iPhone preview"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }

            // Only while actually streaming — after a disconnect the
            // session clears `metadata`, so this bar (and its stats)
            // disappears instead of showing stale numbers.
            if session.metadata != nil {
                VStack {
                    Spacer()
                    statusBar
                }
            }
        }
        .navigationTitle("RemoteCrab Preview")
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.3))
            IBStatusPill(status: session.state.statusPillStatus)
            Text(session.state.message)
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var statusBar: some View {
        IBGlassCard(tint: IBColor.accent, radius: .xl, padding: .m) {
            HStack(spacing: 12) {
                if let md = session.metadata {
                    Label(md.resolutionLabel, systemImage: "rectangle")
                    Label("\(md.fps) fps", systemImage: "speedometer")
                    Label(IBFormat.bitrate(bps: md.bitrateBps), systemImage: "waveform")
                }
                if case .streaming(_, let ms) = session.state {
                    Spacer()
                    Label(IBLocale.Status.latency(ms), systemImage: "bolt.horizontal.fill")
                        .foregroundStyle(IBColor.success)
                }
            }
            .font(IBFont.monoSmall)
            .foregroundStyle(.white.opacity(0.75))
        }
        .padding()
    }
}

extension ReceiverSession.State {
    /// User-facing text for the preview placeholder. Raw `NWError`
    /// descriptions are logged in `ReceiverSession` but never shown
    /// here — the user gets a friendly string instead.
    var message: LocalizedStringKey {
        switch self {
        case .searching:                return "Looking for an iPhone on your WiFi…"
        case .connecting(let name):     return "Connecting to \(name)…"
        case .handshaking(let name):    return "Connecting to \(name)…"
        case .awaitingApproval:         return LocalizedStringKey(IBLocale.Error.awaitingApproval)
        case .streaming(let name, _):   return "Streaming from \(name)"
        case .error(let reason):        return LocalizedStringKey(reason)
        }
    }
}
