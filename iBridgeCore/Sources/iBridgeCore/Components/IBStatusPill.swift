import SwiftUI

/// Live connection status pill — the most-seen element in iBridge.
///
/// Always visible while the app is running. Animates between
/// connected / reconnecting / disconnected states with a pulsing dot.
///
/// The text foreground defaults to white because most surfaces sit on
/// a dark canvas (iOS app, Mac preview / control / test windows).
/// Surfaces that follow the system appearance — the Mac menu-bar
/// popover — must pass `.primary` so the label stays readable in
/// light mode; the status dot carries the color either way.
public struct IBStatusPill: View {

    public enum Status {
        /// Latency is nil until the first ping round-trip completes.
        case connected(latencyMs: Int?)
        case reconnecting
        case disconnected(reason: String)
        /// Calm pre-stream state — nothing has been started yet, so
        /// nothing is wrong. Gray, non-pulsing.
        case idle
        /// Bonjour browse in progress, no peer picked yet.
        case searching
        /// A peer was found and the TCP handshake is in flight.
        case connecting

        var label: String {
            switch self {
            case .connected:                return IBLocale.Status.live
            case .reconnecting:             return IBLocale.Status.reconnecting
            case .disconnected:             return IBLocale.Status.offline
            case .idle:                     return IBLocale.Status.ready
            case .searching:                return IBLocale.Status.looking
            case .connecting:               return IBLocale.Status.connecting
            }
        }

        var ms: String? {
            switch self {
            case .connected(let ms):        return ms.map { "\($0)ms" }
            case .reconnecting, .idle:      return nil
            case .searching, .connecting:   return nil
            case .disconnected(let reason): return reason
            }
        }

        var dotColor: Color {
            switch self {
            case .connected:                return IBColor.success
            case .reconnecting:             return IBColor.warning
            case .disconnected:             return IBColor.error
            case .idle:                     return IBColor.textTertiary
            case .searching, .connecting:   return IBColor.warning
            }
        }

        var isPulsing: Bool {
            switch self {
            case .connected, .reconnecting: return true
            case .searching, .connecting:   return true
            case .disconnected, .idle:      return false
            }
        }
    }

    let status: Status
    let foreground: Color

    public init(status: Status, foreground: Color = .white) {
        self.status = status
        self.foreground = foreground
    }

    private var accessibilityLabel: String {
        switch status {
        case .connected(let ms):
            if let ms {
                return "Connection \(status.label), latency \(ms) milliseconds"
            }
            return "Connection \(status.label)"
        case .disconnected(let reason):
            return "Connection \(status.label). \(reason)"
        case .reconnecting, .idle, .searching, .connecting:
            return "Connection \(status.label)"
        }
    }

    @SwiftUI.State private var pulseScale: CGFloat = 1.0

    public var body: some View {
        HStack(spacing: IBSpace.s.pt) {
            Circle()
                .fill(status.dotColor)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(status.dotColor.opacity(0.4), lineWidth: 4)
                        .scaleEffect(pulseScale)
                        .opacity(status.isPulsing ? 0 : 1)
                }
                .shadow(color: status.dotColor.opacity(0.6), radius: 4, x: 0, y: 0)
                .accessibilityHidden(true)

            Text(status.label)
                .font(IBFont.eyebrowMono)
                .foregroundStyle(foreground)
                .ibEyebrowTracking()

            if let ms = status.ms {
                Text(ms)
                    .font(IBFont.monoSmall)
                    .foregroundStyle(foreground.opacity(0.75))
            }
        }
        .padding(.horizontal, IBSpace.m.pt)
        .padding(.vertical, IBSpace.s.pt - 2)
        .background {
            IBMaterial.bar(in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            guard status.isPulsing else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulseScale = 2.0
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        IBStatusPill(status: .connected(latencyMs: 24))
        IBStatusPill(status: .connected(latencyMs: nil))
        IBStatusPill(status: .idle)
        IBStatusPill(status: .searching)
        IBStatusPill(status: .connecting)
        IBStatusPill(status: .reconnecting)
        IBStatusPill(status: .disconnected(reason: "No WiFi"))
    }
    .padding(40)
    .background(
        LinearGradient(
            colors: [.purple, .blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    )
}