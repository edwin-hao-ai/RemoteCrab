import SwiftUI
import UIKit
import RemoteCrabCore
import os

/// Trackpad mode — the whole screen is the Mac trackpad, driven by the
/// shared `TouchSurface` (drag / click / right-click / scroll with
/// momentum / double-tap-hold drag / pinch / force click / three-finger
/// gestures, with haptics). A live cursor preview follows the finger,
/// and the bottom modifier bar toggles ⌃⌥⌘⇧ that ride on every event.
struct TouchpadScreen: View {
    @EnvironmentObject private var engine: CaptureEngine
    @AppStorage("remotecrab.ios.trackpadSens") private var trackpadSens: Int = 3
    /// Number of times the coach marks have been shown; >= 3 means never again.
    @AppStorage("remotecrab.ios.trackpadCoachShown") private var coachShownCount: Int = 0
    @AppStorage("remotecrab.ios.labAirMouse") private var labAirMouse = false
    @AppStorage("remotecrab.ios.labWheelScroll") private var labWheelScroll = false

    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    @State private var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isPressed = false
    /// Recent touch positions for the motion trail behind the cursor,
    /// newest last. Pruned by age at render time.
    @State private var trail: [(point: CGPoint, at: Date)] = []
    @State private var showCoach = false
    @State private var airMouseActive = false
    @State private var wheelArmed = false
    /// True while a double-tap-hold selection drag is armed; the
    /// cursor preview shows a selection ring.
    @State private var dragArmed = false
    /// True while the drag clutch holds the Mac's button down after a
    /// mid-drag finger lift; a hint pill tells the user they can
    /// reposition and continue.
    @State private var clutching = false

    private static let log = Logger(subsystem: "com.remotecrab", category: "trackpad")

    /// Clearance so the modifier bar floats *above* the whole feature
    /// dock, which is now 118 pt tall (44 pt PTT capsule + 10 pt gap +
    /// 64 pt button row) plus ContentView's 16 pt padding = ~134 pt.
    /// It used to be 88, which let the bar overlap the PTT capsule.
    private let dockClearance: CGFloat = 148

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

    /// A one-shot key (down + up) carrying any locked modifiers.
    private func sendKeyTap(_ keycode: UInt16) {
        let mask = modifierMask
        engine.sendKey(KeyEvent(action: .down, keycode: keycode, modifiers: mask))
        engine.sendKey(KeyEvent(action: .up, keycode: keycode, modifiers: mask))
    }

    /// A compact key button styled like the modifier bar (comma, period,
    /// delete, return — the keys you reach for while navigating).
    private func quickKey(text: String? = nil, symbol: String? = nil, accessibility: String, keycode: UInt16) -> some View {
        Button {
            sendKeyTap(keycode)
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                } else {
                    Text(text ?? "").font(.system(size: 17, weight: .medium))
                }
            }
            .frame(width: 48, height: 48)
            .foregroundStyle(IBColor.textPrimary)
            .background {
                IBMaterial.glass(
                    in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                    tint: IBColor.accent,
                    interactive: true
                )
            }
        }
        .buttonStyle(IBPressButtonStyle())
        .accessibilityLabel(accessibility)
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
                    if pressed {
                        trail.append((location, Date()))
                        if trail.count > 40 { trail.removeFirst(trail.count - 40) }
                    } else {
                        // Joystick convention: lifting the finger
                        // recenters the resting dot, so every new
                        // touch starts from a neutral anchor and the
                        // surface never "runs out" mid-drag.
                        withAnimation(.spring(duration: 0.35)) {
                            cursor = CGPoint(x: 0.5, y: 0.5)
                        }
                    }
                    dismissCoach()
                },
                onDragArmedChange: { armed in
                    withAnimation(IBAnimation.snappy) {
                        dragArmed = armed
                    }
                },
                onClutchChange: { active in
                    withAnimation(IBAnimation.snappy) {
                        clutching = active
                    }
                }
            )
            .ignoresSafeArea()

            cursorPreview
                .allowsHitTesting(false)

            VStack {
                Spacer()
                if labWheelScroll || labAirMouse {
                    HStack {
                        if labWheelScroll {
                            labButton(symbol: "dial.low", active: wheelArmed, label: IBLocale.Labs.wheelScroll) {
                                wheelArmed = $0
                            }
                        }
                        Spacer()
                        if labAirMouse {
                            labButton(symbol: "gyroscope", active: airMouseActive, label: IBLocale.Labs.airMouse) {
                                airMouseActive = $0
                            }
                        }
                    }
                    .padding(.bottom, IBSpace.m.pt)
                }
                if clutching {
                    hintPill(symbol: "hand.raised", text: IBLocale.Trackpad.clutchContinue)
                        .transition(.opacity)
                        .padding(.bottom, IBSpace.s.pt)
                } else if modifiers.contains(.shift) {
                    hintPill(symbol: "shift", text: IBLocale.Trackpad.shiftSelect)
                        .transition(.opacity)
                        .padding(.bottom, IBSpace.s.pt)
                }
                // One horizontally-scrollable key row: the modifiers
                // (leftmost, needed for trackpad gestures) then the
                // common typing keys. A single row instead of two keeps
                // the touch surface clear. "Hold to talk" is deliberately
                // NOT here — it stays a fixed, easy-to-reach control.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: IBSpace.s.pt) {
                        IBModifierBar(activeModifiers: $modifiers)
                        Rectangle()
                            .fill(IBColor.borderSubtle)
                            .frame(width: 1, height: 28)
                        quickKey(symbol: "delete.left", accessibility: IBLocale.A11y.deleteKey, keycode: 51)
                        quickKey(text: ",", accessibility: IBLocale.A11y.commaKey, keycode: 43)
                        quickKey(text: ".", accessibility: IBLocale.A11y.periodKey, keycode: 47)
                        quickKey(symbol: "return", accessibility: IBLocale.A11y.returnKey, keycode: 36)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.bottom, dockClearance)
            }
            .padding(.horizontal, IBSpace.xl.pt)

            if showCoach {
                coachOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        // The whole screen is the trackpad: one-finger drags start at
        // the very bottom edge and must not fight the Home indicator,
        // so the system overlays stay hidden (which also defers edge
        // gestures) while this surface is up.
        .persistentSystemOverlays(.hidden)
        .onAppear {
            maybeShowCoach()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackpadGuideRequested)) { _ in
            withAnimation(IBAnimation.snappy) { showCoach = true }
        }
    }

    // MARK: - Cursor preview

    /// Live cursor preview. While a finger is down the dot follows it
    /// with a fading motion trail; on lift the dot springs back to
    /// center (joystick convention) and rests there dimly.
    private var cursorPreview: some View {
        GeometryReader { geo in
            // Only tick while there's something to animate (finger down
            // or a fading trail). A always-on 20 Hz timeline redrew the
            // Canvas continuously and made the surface switch (and the
            // camera PiP) feel janky.
            TimelineView(.animation(minimumInterval: 0.05,
                                    paused: trail.isEmpty && !isPressed)) { context in
                ZStack(alignment: .topLeading) {
                    // Motion trail: recent touch points fading over
                    // 0.6 s — gives drags a visible "wake".
                    Canvas { ctx, size in
                        let now = context.date
                        for sample in trail {
                            let age = now.timeIntervalSince(sample.at)
                            guard age < 0.6 else { continue }
                            let fade = 1 - age / 0.6
                            let radius = 10 * fade + 3
                            let rect = CGRect(
                                x: sample.point.x * size.width - radius,
                                y: sample.point.y * size.height - radius,
                                width: radius * 2,
                                height: radius * 2
                            )
                            ctx.fill(
                                Path(ellipseIn: rect),
                                with: .color(Color.accentColor.opacity(0.35 * fade))
                            )
                        }
                    }
                    .allowsHitTesting(false)

                    Circle()
                        .fill(Color.accentColor.opacity(isPressed ? 0.95 : 0.35))
                        .frame(width: isPressed ? 56 : 28, height: isPressed ? 56 : 28)
                        .shadow(color: Color.accentColor.opacity(isPressed ? 0.6 : 0), radius: 16)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(isPressed ? 0.6 : 0.25),
                                              lineWidth: 1.5)
                        }
                        .overlay {
                            // Selection-mode ring: double-tap-hold drag
                            // is armed — the Mac is selecting text now.
                            if dragArmed {
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .frame(width: 76, height: 76)
                                    .shadow(color: Color.accentColor.opacity(0.8), radius: 10)
                            }
                        }
                        .position(
                            x: cursor.x * geo.size.width,
                            y: cursor.y * geo.size.height
                        )
                        .scaleEffect(isPressed ? 0.85 : 1.0)
                        .animation(IBAnimation.snappy, value: isPressed)

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
            .accessibilityHint(IBLocale.A11y.holdToActivate)
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Coach marks

    /// The full gesture guide. Shown on the first couple of visits and
    /// re-openable from the top-bar menu. It blocks the surface while up
    /// so it can actually be read (a stray touch can't dismiss it);
    /// tapping the dimmed background closes it.
    private var coachOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { dismissCoach() }

            ScrollView {
                VStack(alignment: .leading, spacing: IBSpace.m.pt) {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(IBLocale.Coach.title)
                            .font(IBFont.titleMedium)
                            .foregroundStyle(.white)
                        Spacer()
                    }

                    coachGroup(IBLocale.Coach.sectionMove, [
                        ("hand.draw", IBLocale.Coach.dragMove),
                        ("hand.tap", IBLocale.Coach.tapClick)
                    ])
                    coachGroup(IBLocale.Coach.sectionScroll, [
                        ("arrow.up.and.down", IBLocale.Coach.twoFingerScroll),
                        ("cursorarrow.click.2", IBLocale.Coach.twoFingerRightClick),
                        ("arrow.up.left.and.arrow.down.right", IBLocale.Coach.pinchZoom)
                    ])
                    coachGroup(IBLocale.Coach.sectionDrag, [
                        ("hand.draw", IBLocale.Coach.doubleTapHoldDrag),
                        ("arrow.left.and.right", IBLocale.Coach.clutchDrag)
                    ])
                    coachGroup(IBLocale.Coach.sectionFingers, [
                        ("hand.point.up", IBLocale.Coach.threeFingerTap),
                        ("rectangle.3.group", IBLocale.Coach.threeFingerSwipe),
                        ("hand.point.up.braille", IBLocale.Coach.forceClick)
                    ])
                    coachGroup(IBLocale.Coach.sectionKeys, [
                        ("command", IBLocale.Coach.modifierBar),
                        ("shift", IBLocale.Coach.shiftSelect),
                        ("delete.left", IBLocale.Coach.quickKeys)
                    ])

                    Button {
                        dismissCoach()
                    } label: {
                        Text(IBLocale.Coach.dismiss)
                            .font(IBFont.bodyLarge)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background { Capsule().fill(IBColor.accent) }
                    }
                    .buttonStyle(IBPressButtonStyle())
                    .padding(.top, IBSpace.xs.pt)
                }
                .padding(20)
                .background {
                    IBMaterial.glass(
                        in: RoundedRectangle(cornerRadius: IBRadius.continuous.pt, style: .continuous)
                    )
                }
                .padding(.horizontal, IBSpace.l.pt)
                .padding(.vertical, 72)
            }
        }
    }

    private func coachGroup(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(IBFont.eyebrowMono)
                .ibEyebrowTracking()
                .foregroundStyle(.white.opacity(0.5))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                coachLine(symbol: row.0, text: row.1)
            }
        }
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

    /// Compact glass capsule for in-context hints (clutch active,
    /// ⇧ locked). Non-interactive: touches fall through to the surface.
    private func hintPill(symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(IBFont.caption)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            IBMaterial.glass(in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private func maybeShowCoach() {
        guard coachShownCount < 2 else { return }
        coachShownCount += 1
        Self.log.debug("trackpad guide shown (\(self.coachShownCount)/2)")
        withAnimation(IBAnimation.gentle) { showCoach = true }
    }

    private func dismissCoach() {
        guard showCoach else { return }
        withAnimation(IBAnimation.snappy) {
            showCoach = false
        }
    }
}

extension Notification.Name {
    /// Posted from the top-bar menu to re-open the trackpad guide.
    static let trackpadGuideRequested = Notification.Name("remotecrab.trackpadGuideRequested")
}
