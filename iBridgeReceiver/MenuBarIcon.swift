import SwiftUI

/// The custom menu bar icon. Drawn in SwiftUI Canvas for pixel-perfect
/// control and crisp rendering at 18pt / 38pt.
///
/// Design: a monochrome line version of the "monitor buddy" mascot —
/// a rounded monitor outline with two eyes and a smile, a signal
/// antenna on top whose tip doubles as the connection status light
/// (green = streaming, orange = connecting, red = error). Line art
/// uses `.primary` so it adapts to light / dark menu bar (white was
/// invisible in light mode); the status dot keeps its color.
struct MenuBarIcon: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / 22
            ctx.scaleBy(x: scale, y: scale)

            // Monitor outline
            let monitor = Path(roundedRect: CGRect(x: 1.2, y: 6, width: 17.6, height: 11.5),
                               cornerRadius: 3.2)
            ctx.stroke(monitor, with: .color(.primary), lineWidth: 1.25)

            // Eyes
            let leftEye = Path(ellipseIn: CGRect(x: 6.9, y: 10.2, width: 1.9, height: 1.9))
            let rightEye = Path(ellipseIn: CGRect(x: 11.2, y: 10.2, width: 1.9, height: 1.9))
            ctx.fill(leftEye, with: .color(.primary))
            ctx.fill(rightEye, with: .color(.primary))

            // Smile
            var smile = Path()
            smile.addArc(center: CGPoint(x: 10, y: 12.2),
                         radius: 2.1,
                         startAngle: .degrees(25),
                         endAngle: .degrees(155),
                         clockwise: false)
            ctx.stroke(smile, with: .color(.primary), lineWidth: 1.0)

            // Stand
            var neck = Path()
            neck.move(to: CGPoint(x: 10, y: 17.5))
            neck.addLine(to: CGPoint(x: 10, y: 19))
            ctx.stroke(neck, with: .color(.primary), lineWidth: 1.25)
            let base = Path(roundedRect: CGRect(x: 6.8, y: 19, width: 6.4, height: 1.3),
                            cornerRadius: 0.65)
            ctx.fill(base, with: .color(.primary))

            // Antenna stem
            var stem = Path()
            stem.move(to: CGPoint(x: 10, y: 6))
            stem.addLine(to: CGPoint(x: 10, y: 3.4))
            ctx.stroke(stem, with: .color(.primary), lineWidth: 1.1)

            // Signal arcs around the antenna tip
            for (radius, opacity) in [(2.9, 0.9), (4.3, 0.45)] as [(CGFloat, Double)] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 10, y: 2.3),
                           radius: radius,
                           startAngle: .degrees(215),
                           endAngle: .degrees(325),
                           clockwise: false)
                ctx.stroke(arc, with: .color(.primary.opacity(opacity)), lineWidth: 0.9)
            }

            // Antenna tip = connection status light
            let dotColor: Color = {
                switch session.state {
                case .streaming:           return .green
                case .searching,
                     .connecting:          return .orange
                case .error:               return .red
                }
            }()
            let tip = Path(ellipseIn: CGRect(x: 8.8, y: 1.1, width: 2.4, height: 2.4))
            ctx.fill(tip, with: .color(dotColor))
        }
    }
}
