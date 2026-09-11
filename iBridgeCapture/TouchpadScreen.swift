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
    @AppStorage("ibridge.ios.labAirMouse") private var labAirMouse = false
    @AppStorage("ibridge.ios.labWheelScroll") private var labWheelScroll = false

    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    @State private var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isPressed = false
    @State private var showCoach = false
    /// Bumped each time the coach marks show/dismiss; the 3.5 s fade
    /// timer compares against it so a stale timer can't clip a newer
    /// showing.
    @State private var coachGeneration = 0
    @State private var airMouseActive = false
    @State private var wheelArmed = false

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
            IBGradient.canvasDark
                .ignoresSafeArea()

            // The actual touch capture surface, covering everything.
            TouchSurface(
                modifierMask: modifierMask,
                sensitivity: trackpadSens,
                airMouseEnabled: labAirMouse,
                wheelScrollEnabled: labWheelScroll,
                airMouseActive: airMouseActive,
                wheelArmed: wheelArmed,
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
                if labWheelScroll || labAirMouse {
                    HStack {
                        if labWheelScroll {
                            labButton(symbol: "dial.low", active: wheelArmed, label: "Wheel scrolling") {
                                wheelArmed = $0
                            }
                        }
                        Spacer()
                        if labAirMouse {
                            labButton(symbol: "gyroscope", active: airMouseActive, label: "Air mouse") {
                                airMouseActive = $0
                            }
                        }
                    }
                    .padding(.bottom, IBSpace.m.pt)
                }
                IBModifierBar(activeModifiers: $modifiers)
                    .padding(.bottom, dockClearance)
            }
            .padding(.horizontal, IBSpace.xl.pt)
        }
        // The whole screen is the trackpad: one-finger drags start at
        // the very bottom edge and must not fight the Home indicator,
        // so the system overlays stay hidden (which also defers edge
        // gestures) while this surface is up.
        .persistentSystemOverlays(.hidden)
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
                    .animation(IBAnimation.snappy, value: cursor)
                    .animation(IBAnimation.snappy, value: isPressed)
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

    // MARK: - Labs floating buttons

    /// Press-and-hold lab button. Holds `held` true for the duration of
    /// the press; the surface reacts to the bridged state.
    private func labButton(
        symbol: String,
        active: Bool,
        label: String,
        onHold: @escaping (Bool) -> Void
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(active ? Color.accentColor : .white.opacity(0.8))
            .frame(width: 48, height: 48)
            .background {
                IBMaterial.bar(in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(active ? 0.5 : 0.12)))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onHold(true) }
                    .onEnded { _ in onHold(false) }
            )
            .accessibilityLabel(label)
            .accessibilityHint("Hold to activate")
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Coach marks

    /// First-run gesture hints. Shown on the first 3 entries into the
    /// trackpad surface; fades out after 3.5 s or on any touch.
    private var coachMarks: some View {
        VStack(spacing: 10) {
            coachLine(symbol: "hand.draw", text: IBLocale.Coach.dragMove)
            coachLine(symbol: "hand.tap", text: IBLocale.Coach.doubleTapHoldDrag)
            coachLine(symbol: "arrow.up.and.down", text: IBLocale.Coach.twoFingerScrollRightClick)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            IBMaterial.glass(
                in: RoundedRectangle(cornerRadius: IBRadius.continuous.pt, style: .continuous)
            )
        }
        // Touches fall through to the surface below, which dismisses.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(IBLocale.Coach.accessibilitySummary)
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
        withAnimation(IBAnimation.gentle) {
            showCoach = true
        }
        coachGeneration += 1
        let generation = coachGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            guard generation == coachGeneration, showCoach else { return }
            withAnimation(IBAnimation.gentle) {
                showCoach = false
            }
        }
    }

    private func dismissCoach() {
        guard showCoach else { return }
        coachGeneration += 1
        withAnimation(IBAnimation.snappy) {
            showCoach = false
        }
    }
}
