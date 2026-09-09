import SwiftUI

/// Live connection status pill — the most-seen element in iBridge.
///
/// Always visible while the app is running. Animates between
/// connected / reconnecting / disconnected states with a pulsing dot.
public struct IBStatusPill: View {

    public enum Status {
        case connected(latencyMs: Int)
        case reconnecting
        case disconnected(reason: String)

        var label: String {
            switch self {
            case .connected:                return "CONNECTED"
            case .reconnecting:             return "RECONNECTING"
            case .disconnected:             return "OFFLINE"
            }
        }

        var ms: String? {
            switch self {
            case .connected(let ms):        return "\(ms)ms"
            case .reconnecting:             return nil
            case .disconnected(let reason): return reason
            }
        }

        var dotColor: Color {
            switch self {
            case .connected:                return IBColor.success
            case .reconnecting:             return IBColor.warning
            case .disconnected:             return IBColor.error
            }
        }

        var isPulsing: Bool {
            switch self {
            case .connected, .reconnecting: return true
            case .disconnected:             return false
            }
        }
    }

    let status: Status

    public init(status: Status) {
        self.status = status
    }

    private var accessibilityLabel: String {
        if let ms = status.ms {
            return "Connection \(status.label), latency \(ms) milliseconds"
        }
        return "Connection \(status.label)"
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
                .foregroundStyle(.white)
                .ibEyebrowTracking()

            if let ms = status.ms {
                Text(ms)
                    .font(IBFont.monoSmall)
                    .foregroundStyle(.white.opacity(0.75))
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