import Foundation
import SwiftUI
import iBridgeCore

/// The connection test window: one screen, four quadrants, each
/// verifying one iPhone → Mac channel in real time.
///
/// Pure display — every value is read from the shared
/// `ReceiverSession` event mirrors (`typedText`, `lastKey`,
/// `touchVisual`, `micLevel`, `latestFrame`). Mirroring happens
/// in `handleInbound` before the normal injection path, so this
/// window never interferes with real input.
struct TestWindowView: View {
    @EnvironmentObject private var session: ReceiverSession

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.14, blue: 0.36),
                    Color(red: 0.42, green: 0.10, blue: 0.50),
                    Color(red: 0.20, green: 0.05, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                header
                HStack(spacing: 12) {
                    cameraCard
                    keyboardCard
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 12) {
                    trackpadCard
                    micCard
                }
                .frame(maxHeight: .infinity)
            }
            .padding(14)
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection Test")
                    .font(IBFont.titleMedium)
                    .foregroundStyle(.white)
                Text("LIVE INPUT VERIFICATION")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.55))
                    .ibEyebrowTracking()
            }
            Spacer()
            IBStatusPill(status: pillStatus)
        }
    }

    private var pillStatus: IBStatusPill.Status {
        switch session.state {
        case .searching:            return .reconnecting
        case .connecting:           return .reconnecting
        case .streaming(_, let ms): return .connected(latencyMs: ms)
        case .error:                return .disconnected(reason: "Offline")
        }
    }

    // MARK: - Camera quadrant

    private var cameraCard: some View {
        quadrantCard(title: "CAMERA", icon: "camera.fill") {
            ZStack {
                if let cg = session.latestFrame {
                    Image(cg, scale: 1, label: Text("Live camera"))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.04)
                    VStack(spacing: 6) {
                        Image(systemName: "camera")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No video")
                            .font(IBFont.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                Text(cameraStats)
                    .font(IBFont.monoSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        Capsule().fill(.black.opacity(0.55))
                    }
                    .padding(6)
            }
        }
    }

    private var cameraStats: String {
        let resolution = session.metadata?.resolutionLabel ?? "—"
        let fps = session.metadata.map { "\($0.fps)" } ?? "—"
        let mbps = session.metadata.map { "\($0.bitrateBps / 1_000_000)" } ?? "—"
        var latency = "—"
        if case .streaming(_, let ms) = session.state { latency = "\(ms)" }
        return "\(resolution) · \(fps) fps · \(mbps) Mbps · \(latency) ms"
    }

    // MARK: - Keyboard quadrant

    private var keyboardCard: some View {
        quadrantCard(title: "KEYBOARD", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 8) {
                lastKeyBadge
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if session.typedText.isEmpty {
                                Text("Type on your iPhone keyboard…")
                                    .font(IBFont.caption)
                                    .foregroundStyle(.white.opacity(0.35))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Text(session.typedText)
                                    .font(IBFont.monoMedium)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("tail")
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.04))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                            }
                    }
                    .onChange(of: session.typedText) {
                        withAnimation {
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lastKeyBadge: some View {
        if let key = session.lastKey {
            HStack(spacing: 6) {
                let mods = modifierSymbols(key.modifiers)
                if !mods.isEmpty {
                    Text(mods)
                        .font(IBFont.monoSmall)
                        .foregroundStyle(IBColor.accent)
                }
                if let code = key.keycode {
                    Text(String(format: "0x%02X", code))
                        .font(IBFont.monoSmall)
                        .foregroundStyle(.white)
                }
                if let text = key.text {
                    Text("\"\(text)\"")
                        .font(IBFont.monoSmall)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 0.5)
                    }
            }
        } else {
            Text("NO KEYS YET")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.35))
                .ibEyebrowTracking()
        }
    }

    /// Modifier glyphs in Apple menu order: ⌃⌥⇧⌘.
    private func modifierSymbols(_ modifiers: UInt8) -> String {
        var result = ""
        if modifiers & TouchEvent.Modifier.control.rawValue != 0 { result += "⌃" }
        if modifiers & TouchEvent.Modifier.option.rawValue != 0 { result += "⌥" }
        if modifiers & TouchEvent.Modifier.shift.rawValue != 0 { result += "⇧" }
        if modifiers & TouchEvent.Modifier.command.rawValue != 0 { result += "⌘" }
        return result
    }

    // MARK: - Trackpad quadrant

    private var trackpadCard: some View {
        quadrantCard(title: "TRACKPAD", icon: "hand.point.up.left.fill") {
            GeometryReader { geo in
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let vis = session.touchVisual
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.04))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            }

                        if let vis {
                            trackpadContents(vis, size: geo.size, now: context.date)
                        } else {
                            Text("Slide on the iPhone trackpad…")
                                .font(IBFont.caption)
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackpadContents(_ vis: TouchVisual, size: CGSize, now: Date) -> some View {
        let pressed = isPressPhase(vis.phase)
        let px = CGFloat(min(max(vis.x, 0), 1)) * size.width
        let py = CGFloat(min(max(vis.y, 0), 1)) * size.height
        // Fully visible for 500 ms after the last event, then fades.
        let elapsed = now.timeIntervalSince(vis.receivedAt)
        let opacity = elapsed < 0.5 ? 1.0 : max(0, 1 - (elapsed - 0.5) / 0.3)

        Circle()
            .fill(pressed ? Color.accentColor : Color.white)
            .frame(width: pressed ? 22 : 14, height: pressed ? 22 : 14)
            .overlay {
                Circle()
                    .strokeBorder(.white, lineWidth: pressed ? 2 : 0)
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .position(x: px, y: py)
            .opacity(opacity)
            .animation(.snappy(duration: 0.15), value: pressed)

        if vis.phase == .scroll {
            let angle = -atan2(Double(vis.dy), Double(vis.dx))
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IBColor.warning)
                .rotationEffect(.radians(angle))
                .position(x: px, y: max(py - 26, 14))
                .opacity(opacity)
        }

        Text(phaseLabel(vis.phase))
            .font(IBFont.eyebrowMono)
            .foregroundStyle(.white)
            .ibEyebrowTracking()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(.black.opacity(0.45))
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func isPressPhase(_ phase: TouchEvent.Phase) -> Bool {
        switch phase {
        case .down, .rightDown, .click:
            return true
        default:
            return false
        }
    }

    /// "dragStart" → "DRAG START".
    private func phaseLabel(_ phase: TouchEvent.Phase) -> String {
        var words: [String] = []
        var current = ""
        for char in phase.rawValue {
            if char.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ").uppercased()
    }

    // MARK: - Microphone quadrant

    private var micCard: some View {
        quadrantCard(title: "MICROPHONE", icon: "mic.fill") {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                HStack {
                    Image(systemName: session.featureState?.micOn ?? false
                          ? "mic.fill" : "mic.slash")
                        .font(.system(size: 16))
                        .foregroundStyle(session.featureState?.micOn ?? false
                                         ? IBColor.success : .white.opacity(0.35))
                    Spacer()
                    Text(String(format: "%3.0f%%", session.micLevel * 100))
                        .font(IBFont.monoMedium)
                        .foregroundStyle(.white)
                }
                GeometryReader { geo in
                    let fraction = CGFloat(min(max(session.micLevel, 0), 1))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                LinearGradient(
                                    colors: [IBColor.success, IBColor.warning, IBColor.error],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: geo.size.width * fraction)
                            }
                    }
                }
                .frame(height: 10)
                .animation(.easeOut(duration: 0.15), value: session.micLevel)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Card chrome

    private func quadrantCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.55))
                    .ibEyebrowTracking()
                Spacer()
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
    }
}
