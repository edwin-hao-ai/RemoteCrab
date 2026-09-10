import SwiftUI
import UIKit
import iBridgeCore
import os

/// Trackpad mode — the whole screen is the Mac trackpad, driven by the
/// shared `TouchSurface` (drag / click / right-click / scroll with
/// momentum / double-tap-hold drag / pinch / force click / three-finger
/// gestures, with haptics). A live cursor preview follows the finger,
/// and the bottom modifier bar toggles ⌃⌥⌘⇧ that ride on every event.
struct TouchpadScreen: View {
    @EnvironmentObject private var engine: CaptureEngine
    @AppStorage("ibridge.ios.trackpadSens") private var trackpadSens: Int = 3
    /// Number of times the coach marks have been shown; >= 3 means never again.
    @AppStorage("ibridge.ios.trackpadCoachShown") private var coachShownCount: Int = 0

    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    @State private var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isPressed = false
    @State private var showCoach = false

    private static let log = Logger(subsystem: "com.ibridge", category: "trackpad")

    /// Feature dock height (48 pt buttons + 16 pt vertical padding)
    /// plus ContentView's outer padding — the modifier bar floats above it.
    private let dockClearance: CGFloat = 88

    /// Modifier bitmask shared with TouchEvent: shift=1, control=2,
    /// option=4, command=8.
    private var modifierMask: UInt8 {
        var mask: UInt8 = 0
        if modifiers.contains(.shift) { mask |= 1 }
        if modifiers.contains(.control) { mask |= 2 }
        if modifiers.contains(.option) { mask |= 4 }
        if modifiers.contains(.command) { mask |= 8 }
        return mask
    }

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

            // The actual touch capture surface, covering everything.
            TouchSurface(
                modifierMask: modifierMask,
                sensitivity: trackpadSens,
                onEvent: { event in
                    engine.sendTouch(event)
                },
                onTouch: { location, pressed in
                    cursor = location
                    isPressed = pressed
                    dismissCoach()
                }
            )
            .ignoresSafeArea()

            cursorPreview
                .allowsHitTesting(false)

            VStack {
                Spacer()
                if showCoach {
                    coachMarks
                        .transition(.opacity)
                }
                Spacer()
                IBModifierBar(activeModifiers: $modifiers)
                    .padding(.bottom, dockClearance)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            maybeShowCoach()
        }
    }

    // MARK: - Cursor preview

    /// Live cursor preview. Visible while a finger is on the screen,
    /// fades out within 200 ms after lift.
    private var cursorPreview: some View {
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

                // Subtle vertical scan line while pressed, hinting
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
    }

    // MARK: - Coach marks

    /// First-run gesture hints. Shown on the first 3 entries into the
    /// trackpad surface; fades out after 3.5 s or on any touch.
    private var coachMarks: some View {
        VStack(spacing: 10) {
            coachLine(symbol: "hand.draw", text: "拖动 = 移动光标")
            coachLine(symbol: "hand.tap", text: "双击按住 = 拖拽")
            coachLine(symbol: "arrow.up.and.down", text: "双指 = 滚动 · 右键")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.black.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        }
        // Touches fall through to the surface below, which dismisses.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trackpad gestures: drag to move the cursor, double-tap and hold to drag, two fingers to scroll or right-click")
    }

    private func coachLine(symbol: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28)
            Text(text)
                .font(IBFont.bodyMedium)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private func maybeShowCoach() {
        guard coachShownCount < 3 else { return }
        coachShownCount += 1
        Self.log.debug("coach marks shown (\(self.coachShownCount)/3)")
        withAnimation(.easeIn(duration: 0.4)) {
            showCoach = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.5)) {
                showCoach = false
            }
        }
    }

    private func dismissCoach() {
        guard showCoach else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            showCoach = false
        }
    }
}
