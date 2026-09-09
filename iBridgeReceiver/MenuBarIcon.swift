import SwiftUI

/// The custom menu bar icon. Drawn in SwiftUI Canvas for pixel-perfect
/// control and crisp rendering at 18pt / 38pt.
///
/// Design: an "iPhone" outline with three wifi waves emanating to the
/// right, plus a small status dot in the top-right that turns green
/// when connected. Tinted to follow the system template so it adapts
/// to light / dark menu bar automatically.
struct MenuBarIcon: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / 22
            ctx.scaleBy(x: scale, y: scale)

            // iPhone outline
            let phoneRect = CGRect(x: 0.5, y: 3, width: 8, height: 16)
            let phone = Path(roundedRect: phoneRect, cornerRadius: 2.2)
            ctx.stroke(phone, with: .color(.white), lineWidth: 1.2)

            // Screen notch
            let notch = Path(roundedRect: CGRect(x: 3, y: 4, width: 3, height: 0.8),
                             cornerRadius: 0.4)
            ctx.fill(notch, with: .color(.white))

            // Home indicator
            let home = Path(roundedRect: CGRect(x: 2.5, y: 16.5, width: 4, height: 0.6),
                            cornerRadius: 0.3)
            ctx.fill(home, with: .color(.white.opacity(0.5)))

            // Three wifi waves emanating to the right
            let baseX: CGFloat = 9
            let baseY: CGFloat = 11
            for i in 0..<3 {
                let r = 1.8 + CGFloat(i) * 1.8
                let path = Path { p in
                    p.addArc(center: CGPoint(x: baseX, y: baseY),
                             radius: r,
                             startAngle: .degrees(-50),
                             endAngle: .degrees(50),
                             clockwise: false)
                }
                ctx.stroke(path,
                           with: .color(.white.opacity(0.95 - Double(i) * 0.25)),
                           lineWidth: 1.0)
            }

            // Status dot
            let status = session.state
            let dotColor: Color = {
                switch status {
                case .streaming:    return .green
                case .searching,
                     .connecting:   return .orange
                case .error:        return .red
                }
            }()
            let dot = Path(ellipseIn: CGRect(x: 17, y: 1, width: 4, height: 4))
            ctx.fill(dot, with: .color(dotColor))
        }
    }
}