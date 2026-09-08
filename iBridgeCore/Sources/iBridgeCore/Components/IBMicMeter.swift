import SwiftUI

/// Animated microphone input meter — 10 vertical bars that
/// show the current mic level in real time.
///
/// Updated every frame by passing in new `level` values (0.0 ... 1.0).
public struct IBMicMeter: View {

    public static let barCount = 10

    let level: Float          // 0.0 ... 1.0
    let isActive: Bool

    public init(level: Float, isActive: Bool = true) {
        self.level = level
        self.isActive = isActive
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let threshold = Float(index + 1) / Float(Self.barCount)
                let isLit = isActive && level >= threshold * 0.95
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
                    .opacity(isLit ? 1.0 : 0.18)
                    .animation(IBAnimation.snappy, value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Slightly increasing heights across the row, mimicking classic
        // broadcast level meters.
        let baseHeights: [CGFloat] = [4, 6, 8, 10, 12, 14, 16, 17, 18, 18]
        return baseHeights[index]
    }

    private func barColor(for index: Int) -> Color {
        let position = Float(index) / Float(Self.barCount - 1)
        if position > 0.85 { return IBColor.recording }
        if position > 0.65 { return IBColor.warning }
        return IBColor.success
    }
}

#Preview {
    StatefulPreviewWrapper(Float(0.6)) { binding in
        VStack(spacing: 20) {
            IBMicMeter(level: binding.wrappedValue)
            Slider(value: binding, in: 0...1)
                .padding(.horizontal, 40)
        }
        .padding()
        .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}