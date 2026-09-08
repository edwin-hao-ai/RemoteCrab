import SwiftUI
import iBridgeCore

/// Floating control panel — uses the full iBridge Design System
/// including the Liquid Glass IBGlassCard.
struct ControlPanelView: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        IBGlassCard(tint: IBColor.accent, radius: .xl, padding: .l) {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().opacity(0.15)
                devicesSection
                if let md = session.metadata {
                    Divider().opacity(0.15)
                    streamSection(md)
                }
                Divider().opacity(0.15)
                statusFooter
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.25, blue: 0.55), Color(red: 0.40, green: 0.15, blue: 0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .onAppear { session.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("iBridge")
                    .font(IBFont.displayMedium)
                Spacer()
                IBStatusPill(status: pillStatus)
            }
            Text("Receiver")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.55))
                .ibEyebrowTracking()
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISCOVERED")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.55))
                .ibEyebrowTracking()
            if session.discovered.isEmpty {
                Text("No devices found")
                    .font(IBFont.bodySmall)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(session.discovered) { phone in
                    HStack {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(.white.opacity(0.7))
                        Text(phone.name)
                            .font(IBFont.bodyMedium)
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(phone.port)")
                            .font(IBFont.monoSmall)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func streamSection(_ md: IBStreamMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STREAM")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.55))
                .ibEyebrowTracking()
            row("Resolution", md.resolutionLabel)
            row("FPS", "\(md.fps)")
            row("Bitrate", "\(md.bitrateBps / 1_000_000) Mbps")
            row("Codec", md.codec.uppercased())
        }
    }

    private var statusFooter: some View {
        HStack {
            Image(systemName: session.latestFrame == nil ? "circle" : "circle.fill")
                .foregroundStyle(session.latestFrame == nil ? IBColor.warning : IBColor.success)
            Text(session.state.message)
                .font(IBFont.bodySmall)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(IBFont.bodySmall)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(IBFont.monoMedium)
                .foregroundStyle(.white)
        }
    }

    private var pillStatus: IBStatusPill.Status {
        switch session.state {
        case .searching:        return .reconnecting
        case .connecting:       return .reconnecting
        case .streaming(_, let ms): return .connected(latencyMs: ms)
        case .error:            return .disconnected(reason: "Offline")
        }
    }
}