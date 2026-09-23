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
    @AppStorage("remotecrab.ios.scrollSens") private var scrollSens: Int = 3
    @AppStorage("remotecrab.ios.naturalScroll") private var naturalScroll: Bool = true
    @AppStorage("remotecrab.ios.hapticStrength") private var hapticStrength: Int = 2
    @State private var showSelectionBar = false
    @State private var selectionBarTask: Task<Void, Never>?
    @AppStorage("remotecrab.ios.labAirMouse") private var labAirMouse = false
    @AppStorage("remotecrab.ios.labWheelScroll") private var labWheelScroll = false

    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    @State private var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isPressed = false
    /// Recent touch positions for the motion trail behind the cursor,
    /// newest last. Pruned by age at render time.
    @State private var trail: [(point: CGPoint, at: Date)] = []
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

    /// Clearance so the modifier/quick-key row floats *above* the
    /// bottom PTT row (⌨️ button + hold-to-talk capsule), which is
    /// 48 pt tall plus ContentView's 16 pt padding — ~64 pt, plus a
    /// small margin.
    private let dockClearance: CGFloat = 76

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
    /// `prominent` fills the key with the accent color (used for ⏎).
    private func quickKey(text: String? = nil, symbol: String? = nil, accessibility: String, keycode: UInt16, prominent: Bool = false) -> some View {
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
            .foregroundStyle(prominent ? .white : IBColor.textPrimary)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                        .fill(Color.accentColor)
                } else {
                    IBMaterial.glass(
                        in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                        tint: IBColor.accent,
                        interactive: true
                    )
                }
            }
            // On the LABEL: a custom ButtonStyle hit-tests the label's
            // content shape, not the outer button bounds.
            .contentShape(RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous))
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
                scrollSensitivity: scrollSens,
                naturalScroll: naturalScroll,
                hapticStrength: hapticStrength,
                onDragEnded: { flashSelectionBar() },
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
                if showSelectionBar {
                    selectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, IBSpace.s.pt)
                }
                // One horizontally-scrollable key row: the modifiers
                // (leftmost, needed for trackpad gestures) then the
                // common typing keys. A single row instead of two keeps
                // the touch surface clear. "Hold to talk" is deliberately
                // NOT here — it stays a fixed, easy-to-reach control.
                // The context chip is pinned OUTSIDE the ScrollView so it
                // never scrolls away.
                HStack(spacing: IBSpace.s.pt) {
                    contextChip
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: IBSpace.s.pt) {
                            // ⏎/⌫ lead the row: after voice dictation the
                            // next reach is always "edit" or "send".
                            quickKey(symbol: "return", accessibility: IBLocale.A11y.returnKey, keycode: 36, prominent: true)
                            quickKey(symbol: "delete.left", accessibility: IBLocale.A11y.deleteKey, keycode: 51)
                            // esc sits right after ⏎/⌫ — the quickest way
                            // to cancel a dialog, menu or search field.
                            quickKey(text: "esc", accessibility: IBLocale.A11y.escapeKey, keycode: 53)
                            Rectangle()
                                .fill(IBColor.borderSubtle)
                                .frame(width: 1, height: 28)
                            IBModifierBar(activeModifiers: $modifiers,
                                          onModifierKey: { code, down in
                                              engine.sendKey(KeyEvent(action: down ? .down : .up, keycode: code))
                                          })
                            quickKey(text: ",", accessibility: IBLocale.A11y.commaKey, keycode: 43)
                            quickKey(text: ".", accessibility: IBLocale.A11y.periodKey, keycode: 47)
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.bottom, dockClearance)
            }
            .padding(.horizontal, IBSpace.xl.pt)
        }
        // The whole screen is the trackpad: one-finger drags start at
        // the very bottom edge and must not fight the Home indicator,
        // so the system overlays stay hidden (which also defers edge
        // gestures) while this surface is up.
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Selection actions

    /// Shown for a few seconds after a drag (a likely text selection on
    /// the Mac), offering the copy/paste chords you'd get from a system
    /// edit menu.
    private var selectionBar: some View {
        HStack(spacing: IBSpace.s.pt) {
            selectionAction("Copy", "doc.on.doc", 8)          // ⌘C
            selectionAction("Cut", "scissors", 7)             // ⌘X
            selectionAction("Paste", "doc.on.clipboard", 9)   // ⌘V
            selectionAction("Select All", "selection.pin.in.out", 0) // ⌘A
        }
        .padding(6)
        .background {
            IBMaterial.glass(in: Capsule(), tint: IBColor.accent, interactive: true)
        }
        .accessibilityElement(children: .contain)
    }

    private func selectionAction(_ label: String, _ symbol: String, _ keycode: UInt16) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            engine.sendKey(KeyEvent(action: .down, keycode: keycode, modifiers: 8))
            engine.sendKey(KeyEvent(action: .up, keycode: keycode, modifiers: 8))
            hideSelectionBar()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                Text(LocalizedStringKey(label)).font(IBFont.caption)
            }
            .foregroundStyle(.white)
            .frame(minWidth: 56, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    private func flashSelectionBar() {
        withAnimation(IBAnimation.snappy) { showSelectionBar = true }
        selectionBarTask?.cancel()
        selectionBarTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            hideSelectionBar()
        }
    }

    private func hideSelectionBar() {
        selectionBarTask?.cancel()
        selectionBarTask = nil
        withAnimation(IBAnimation.snappy) { showSelectionBar = false }
    }

    // MARK: - Cursor preview

    /// Frontmost-app context chip, pinned left of the key row. Opens
    /// the context sheet (Task 7). Data: engine.frontmostMacApp.
    private var contextChip: some View {
        Button {
            engine.showContextSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.frontmostMacApp?.name ?? "Computer")
                    .font(IBFont.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background {
                IBMaterial.glass(
                    in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                    tint: IBColor.accent,
                    interactive: true
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous))
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.9))
        .accessibilityLabel(IBLocale.Context.open)
    }

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

}

