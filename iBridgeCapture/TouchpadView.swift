import SwiftUI
import UIKit
import iBridgeCore

/// A SwiftUI wrapper around `UIView` that captures multi-touch gestures
/// and converts them to `TouchEvent`s. The whole screen is a touch
/// surface — drag to move the Mac cursor, tap to click, two-finger
/// drag to scroll, two-finger tap to right-click.
struct TouchpadView: UIViewRepresentable {
    let onEvent: (TouchEvent) -> Void

    func makeUIView(context: Context) -> TouchpadUIView {
        let view = TouchpadUIView()
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ uiView: TouchpadUIView, context: Context) {
        uiView.onEvent = onEvent
    }
}

final class TouchpadUIView: UIView {

    var onEvent: ((TouchEvent) -> Void)?
    private var modifierMask: UInt8 = 0
    private var lastDragLocation: CGPoint?
    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        // Single-finger pan = mouse move + left-button drag.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)

        // Two-finger pan = scroll wheel.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.cancelsTouchesInView = false
        addGestureRecognizer(scroll)

        // Single tap = left click.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        addGestureRecognizer(tap)

        // Two-finger tap = right click.
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap(_:)))
        rightTap.numberOfTapsRequired = 1
        rightTap.numberOfTouchesRequired = 2
        addGestureRecognizer(rightTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Modifier tracking

    func setModifier(_ modifier: TouchEvent.Modifier, on: Bool) {
        let bit = modifier.rawValue
        if on { modifierMask |= bit } else { modifierMask &= ~bit }
    }

    // MARK: - Gestures

    @objc private func handlePan(_ rec: UIPanGestureRecognizer) {
        let location = rec.location(in: self)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        switch rec.state {
        case .began:
            isDragging = true
            lastDragLocation = location
            emit(.init(
                phase: .down,
                x: Float(location.x / bounds.width),
                y: Float(location.y / bounds.height),
                modifiers: modifierMask,
                timestampMicros: timestamp
            ))
        case .changed:
            guard let last = lastDragLocation else { return }
            let dx = Float(location.x - last.x) / Float(bounds.width)
            let dy = Float(location.y - last.y) / Float(bounds.height)
            lastDragLocation = location
            emit(.init(
                phase: .move,
                x: Float(location.x / bounds.width),
                y: Float(location.y / bounds.height),
                dx: dx,
                dy: dy,
                modifiers: modifierMask,
                timestampMicros: timestamp
            ))
        case .ended, .cancelled, .failed:
            isDragging = false
            lastDragLocation = nil
            emit(.init(
                phase: .up,
                x: Float(location.x / bounds.width),
                y: Float(location.y / bounds.height),
                modifiers: modifierMask,
                timestampMicros: timestamp
            ))
        default:
            break
        }
    }

    @objc private func handleScroll(_ rec: UIPanGestureRecognizer) {
        guard rec.state == .changed || rec.state == .ended else { return }
        let translation = rec.translation(in: self)
        // Reset so we always get a delta since the last event.
        rec.setTranslation(.zero, in: self)
        let dx = Float(translation.x) / Float(bounds.width)
        let dy = Float(translation.y) / Float(bounds.height)
        emit(.init(
            phase: .scroll,
            x: 0, y: 0, dx: dx, dy: dy,
            modifiers: modifierMask,
            timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)
        ))
    }

    @objc private func handleTap(_ rec: UITapGestureRecognizer) {
        let location = rec.location(in: self)
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

    private func emit(_ event: TouchEvent) {
        onEvent?(event)
    }
}