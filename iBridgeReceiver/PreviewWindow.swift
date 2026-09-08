import SwiftUI
import iBridgeCore

/// The main preview window — shows the most recently decoded H.264
/// frame from the iPhone. Uses `ImageRenderer` to display CGImage
/// efficiently without re-encoding on every frame.
struct PreviewWindow: View {
    @EnvironmentObject private var session: ReceiverSession
    @State private var renderer: ImageRenderer<AnyView>?

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

            if !session.discovered.isEmpty {
                VStack {
                    Spacer()
                    statusBar
                }
            }
        }
        .navigationTitle("iBridge Preview")
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.3))
            Text(session.state.message)
                .font(IBFont.bodyMedium)
                .foregroundStyle(.white.opacity(0.6))
            if case .searching = session.state {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.6))
            }
        }
    }

    private var statusBar: some View {
        IBGlassCard(tint: IBColor.accent, radius: .xl, padding: .m) {
            HStack(spacing: 12) {
                if let md = session.metadata {
                    Label(md.resolutionLabel, systemImage: "rectangle")
                    Label("\(md.fps) fps", systemImage: "speedometer")
                    Label("\(md.bitrateBps / 1_000_000) Mbps", systemImage: "waveform")
                }
                if case .streaming(_, let ms) = session.state {
                    Spacer()
                    Label("\(ms)ms", systemImage: "bolt.horizontal.fill")
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
    var message: String {
        switch self {
        case .searching:                return "Looking for an iPhone on your WiFi…"
        case .connecting(let name):     return "Connecting to \(name)…"
        case .streaming(let name, _):   return "Streaming from \(name)"
        case .error(let msg):           return "Error: \(msg)"
        }
    }
}