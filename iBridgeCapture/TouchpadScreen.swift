import SwiftUI
import UIKit
import iBridgeCore

/// Touchpad mode — full-screen touch surface with visual cursor
/// preview. The whole screen is the trackpad:
/// • single-finger drag → move the Mac cursor
/// • tap → left click
/// • two-finger drag → scroll
/// • two-finger tap → right click
/// • modifier buttons at the bottom toggle ⌃⌥⌘⇧
struct TouchpadScreen: View {
    @EnvironmentObject private var engine: CaptureEngine
    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    @State private var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isPressed = false

    var body: some View {
        ZStack {
            // Subtle background — dark with a hint of color, so the
            // user knows the surface is alive.
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.10),
                    Color(red: 0.10, green: 0.05, blue: 0.16)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Live cursor preview. Visible while a finger is on the
            // screen, fades out within 200 ms after lift.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.95))
                        .frame(width: 56, height: 56)
                        .shadow(color: Color.accentColor.opacity(0.6), radius: 16)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                        }
                        .position(
                            x: cursor.x * geo.size.width,
                            y: cursor.y * geo.size.height
                        )
                        .scaleEffect(isPressed ? 0.85 : 1.0)
                        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: cursor)
                        .animation(.spring(response: 0.12, dampingFraction: 0.6), value: isPressed)
                        .opacity(isPressed ? 1.0 : 0.85)

                    // Subtle vertical + horizontal scan line, hinting
                    // "the whole screen is the touch surface".
                    if isPressed {
                        Path { p in
                            let x = cursor.x * geo.size.width
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                        .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                    }
                }
            }

            VStack {
                topHints
                Spacer()
                gestureHints
                Spacer()
                modifierBar
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // The actual touch capture surface, covering everything.
            TouchpadCaptureSurface(
                modifiers: $modifiers,
                cursor: $cursor,
                isPressed: $isPressed,
                onEvent: { event in
                    engine.sendTouch(event)
                }
            )
            .ignoresSafeArea()
        }
    }

    private var topHints: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(.white.opacity(0.7))
                Text("TRACKPAD MODE")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.7))
                    .ibEyebrowTracking()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.black.opacity(0.5))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            }
        }
        .padding(.top, 8)
    }

    private var gestureHints: some View {
        VStack(spacing: 10) {
            hint(symbol: "hand.draw", text: "Drag", description: "Move cursor")
            hint(symbol: "circle.dashed", text: "Tap", description: "Left click")
            hint(symbol: "rectangle.portrait", text: "Two fingers", description: "Scroll / right click")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.black.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        }
    }

    private func hint(symbol: String, text: String, description: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(.white)
                Text(description)
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    private var modifierBar: some View {
        VStack(spacing: 8) {
            Text("MODIFIER KEYS")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.5))
                .ibEyebrowTracking()
            IBModifierBar(activeModifiers: $modifiers)
                .onChange(of: modifiers) { _, new in
                    for m in IBModifierBar.Modifier.allCases {
                        if new.contains(m) {
                            engine.sendTouch(TouchEvent(
                                phase: .down,
                                modifiers: modifierBitmask(for: m)
                            ))
                        }
                    }
                }
        }
    }
}

// MARK: - Touch capture

/// Map our String-keyed modifier enum to the bitmask expected by
/// `TouchEvent.modifiers`.
private func modifierBitmask(for m: IBModifierBar.Modifier) -> UInt8 {
    switch m {
    case .control: return 1 << 1
    case .option:  return 1 << 2
    case .command: return 1 << 3
    case .shift:   return 1 << 0
    }
}

private struct TouchpadCaptureSurface: UIViewRepresentable {
    @Binding var modifiers: Set<IBModifierBar.Modifier>
    @Binding var cursor: CGPoint
    @Binding var isPressed: Bool
    let onEvent: (TouchEvent) -> Void

    func makeUIView(context: Context) -> TouchpadUIView {
        let view = TouchpadUIView()
        view.onEvent = onEvent
        view.onTouch = { location, pressed in
            DispatchQueue.main.async {
                cursor = location
                isPressed = pressed
            }
        }
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Trackpad surface. Touch and drag to move the Mac cursor."
        view.accessibilityTraits = .allowsDirectInteraction
        return view
    }

    func updateUIView(_ uiView: TouchpadUIView, context: Context) {
        uiView.onEvent = onEvent
        uiView.onTouch = { location, pressed in
            DispatchQueue.main.async {
                cursor = location
                isPressed = pressed
            }
        }
    }
}

final class TouchpadUIView: UIView {

    var onEvent: ((TouchEvent) -> Void)?
    var onTouch: ((CGPoint, Bool) -> Void)?

    private var modifierMask: UInt8 = 0
    private var lastDragLocation: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.cancelsTouchesInView = false
        addGestureRecognizer(scroll)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        addGestureRecognizer(rightTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handlePan(_ rec: UIPanGestureRecognizer) {
        let location = rec.location(in: self)
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        switch rec.state {
        case .began:
            lastDragLocation = location
            onTouch?(normalize(location), true)
            emit(.init(
                phase: .down,
                x: Float(location.x / bounds.width),
                y: Float(location.y / bounds.height),
                modifiers: modifierMask,
                timestampMicros: ts
            ))
        case .changed:
            guard let last = lastDragLocation else { return }
            let dx = Float(location.x - last.x) / Float(bounds.width)
            let dy = Float(location.y - last.y) / Float(bounds.height)
            lastDragLocation = location
            onTouch?(normalize(location), true)
            emit(.init(
                phase: .move,
                x: Float(location.x / bounds.width),
                y: Float(location.y / bounds.height),
                dx: dx, dy: dy,
                modifiers: modifierMask,
                timestampMicros: ts
            ))
        case .ended, .cancelled, .failed:
            lastDragLocation = nil
            onTouch?(normalize(location), false)
            emit(.init(
                phase: .up,
                x: Float(location.x / bounds.width),
                y: Float(location.y / bounds.height),
                modifiers: modifierMask,
                timestampMicros: ts
            ))
        default:
            break
        }
    }

    @objc private func handleScroll(_ rec: UIPanGestureRecognizer) {
        guard rec.state == .changed || rec.state == .ended else { return }
        let translation = rec.translation(in: self)
        rec.setTranslation(.zero, in: self)
        let dx = Float(translation.x) / Float(bounds.width)
        let dy = Float(translation.y) / Float(bounds.height)
        emit(.init(
            phase: .scroll, dx: dx, dy: dy,
            modifiers: modifierMask,
            timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)
        ))
    }

    @objc private func handleTap(_ rec: UITapGestureRecognizer) {
        let location = rec.location(in: self)
        onTouch?(normalize(location), false)
        emit(.init(
            phase: .click,
            x: Float(location.x / bounds.width),
            y: Float(location.y / bounds.height),
            modifiers: modifierMask,
            timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)
        ))
    }

    @objc private func handleRightTap(_ rec: UITapGestureRecognizer) {
        let location = rec.location(in: self)
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        emit(.init(phase: .rightDown, x: Float(location.x / bounds.width), y: Float(location.y / bounds.height), modifiers: modifierMask, timestampMicros: ts))
        emit(.init(phase: .rightUp, x: Float(location.x / bounds.width), y: Float(location.y / bounds.height), modifiers: modifierMask, timestampMicros: ts &+ 1))
    }

    private func normalize(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
    }

    private func emit(_ event: TouchEvent) {
        onEvent?(event)
    }
}