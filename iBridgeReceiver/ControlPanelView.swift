import SwiftUI
import iBridgeCore

/// The Mac receiver's primary control panel. V0.2 — designed for
/// information density without sacrificing the Apple Native + Liquid
/// Glass aesthetic.
///
/// Layout (top to bottom):
///   • Header: app identity + connection status pill
///   • Hero row: live preview thumbnail + stream stats card
///   • Latency sparkline (last 30 frames)
///   • Device + session metadata
///   • Quick action buttons
struct ControlPanelView: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        ZStack {
            // Background gradient — also shows through Liquid Glass.
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.14, blue: 0.36),
                    Color(red: 0.42, green: 0.10, blue: 0.50),
                    Color(red: 0.20, green: 0.05, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                header
                heroRow
                latencyCard
                deviceCard
                Spacer(minLength: 0)
                actionRow
            }
            .padding(16)
        }
        .frame(width: 380, height: 620)
        .onAppear { session.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("iBridge")
                    .font(IBFont.displayMedium)
                    .foregroundStyle(.white)
                Text("Mac receiver")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.55))
                    .ibEyebrowTracking()
            }
            Spacer()
            IBStatusPill(status: pillStatus)
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

    // MARK: - Hero row (preview + stats)

    private var heroRow: some View {
        HStack(spacing: 10) {
            previewThumbnail
                .frame(width: 150, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
            statsCard
        }
    }

    private var previewThumbnail: some View {
        ZStack {
            if let cg = session.latestFrame {
                Image(cg, scale: 1, label: Text("Preview"))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 6) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No preview")
                        .font(IBFont.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            statRow("Resolution",
                    value: session.metadata?.resolutionLabel ?? "—",
                    sf: "rectangle")
            statRow("Frame rate",
                    value: session.metadata.map { "\($0.fps) fps" } ?? "—",
                    sf: "speedometer")
            statRow("Bitrate",
                    value: session.metadata.map { "\($0.bitrateBps / 1_000_000) Mbps" } ?? "—",
                    sf: "waveform")
            statRow("Codec",
                    value: (session.metadata?.codec ?? "h264").uppercased(),
                    sf: "lock.shield")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
    }

    private func statRow(_ label: String, value: String, sf: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sf)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            Text(label)
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(IBFont.monoMedium)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Latency sparkline

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LATENCY")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.55))
                    .ibEyebrowTracking()
                Spacer()
                Text("\(currentLatency) ms")
                    .font(IBFont.monoMedium)
                    .foregroundStyle(latencyColor)
                    .ibNumericSpring(value: currentLatency)
            }
            // Inline mini-sparkline. Pure SwiftUI Path so we don't need
            // an extra dependency on Charts.
            Sparkline(samples: latencySamples, color: latencyColor)
                .frame(height: 32)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
    }

    private var currentLatency: Int {
        if case .streaming(_, let ms) = session.state { return ms }
        return 0
    }

    private var latencyColor: Color {
        switch currentLatency {
        case 0:        return .white.opacity(0.4)
        case 1...50:   return IBColor.success
        case 51...150: return IBColor.warning
        default:       return IBColor.error
        }
    }

    /// Simulated latency samples — replaced with a real ring buffer
    /// when the connection pipeline lands. For now the curve stays
    /// visually consistent.
    private var latencySamples: [Double] {
        let baseline = max(currentLatency, 24)
        return (0..<30).map { i in
            let phase = Double(i) * 0.42
            return Double(baseline) + sin(phase) * 6.0
        }
    }

    // MARK: - Device + session

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 14)
                Text(session.discovered.first?.name ?? "—")
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(.white)
                Spacer()
                if let phone = session.discovered.first {
                    Text(phone.endpoint)
                        .font(IBFont.monoSmall)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Divider().opacity(0.15)
            HStack {
                badge("CAM", active: session.featureState?.cameraOn ?? false)
                badge("MIC", active: session.featureState?.micOn ?? false)
                badge("TPAD", active: session.featureState?.trackpadOn ?? false)
                badge("KEY", active: session.featureState?.keyboardOn ?? false)
                Spacer()
                Text("V0.2")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.4))
                    .ibEyebrowTracking()
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
    }

    private func badge(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(IBFont.eyebrowMono)
            .foregroundStyle(active ? .white : .white.opacity(0.4))
            .ibEyebrowTracking()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1),
                                          lineWidth: 1)
                    }
            }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
            } label: {
                Label("Preview", systemImage: "rectangle.on.rectangle")
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor)
                    }
            }
            .buttonStyle(.plain)

            Menu {
                Button("OpenPreviewWindow") { /* ... */ }
                Divider()
                Button("Quit iBridge") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.white.opacity(0.1))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                            }
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Sparkline

private struct Sparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }

            let maxVal = samples.max() ?? 1
            let minVal = samples.min() ?? 0
            let range = max(maxVal - minVal, 1)

            // Compute the path through sample space.
            var path = Path()
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) / CGFloat(samples.count - 1) * size.width
                let normalized = (sample - minVal) / range
                let y = size.height - CGFloat(normalized) * size.height * 0.8 - 2
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Filled area underneath.
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.18)))

            ctx.stroke(path, with: .color(color), lineWidth: 1.4)
        }
    }
}