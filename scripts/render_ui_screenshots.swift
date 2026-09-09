import SwiftUI
import UIKit
import iBridgeCore

/// Renders the V0.2 iOS UI screens to PNG so we can see what the
/// Liquid Glass design looks like without needing a real device.
///
/// Usage (from the project root):
///     swift scripts/render_ui_screenshots.swift
///
/// Output:
///     /tmp/ibridge_camera.png
///     /tmp/ibridge_trackpad.png
///     /tmp/ibridge_keyboard.png
///     /tmp/ibridge_mic.png

@MainActor
enum UIRenderer {
    static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 3.0
        if let cg = renderer.cgImage {
            let ui = UIImage(cgImage: cg)
            if let data = ui.pngData() {
                try? data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)  (\(cg.width)×\(cg.height))")
            }
        }
    }
}

// MARK: - Camera screen (offline, dark mode)

let camera = ZStack {
    Color.black

    VStack {
        HStack(spacing: 8) {
            IBStatusPill(status: .disconnected(reason: "No Mac found"))
            Spacer()
            HStack(spacing: 6) {
                ForEach([0, 1, 2], id: \.self) { i in
                    Image(systemName: ["camera.fill", "hand.point.up.left.fill", "keyboard"][i])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(i == 0 ? .white : .white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background {
                            if i == 0 {
                                IBMaterial.bar(in: Circle())
                            }
                        }
                }
            }
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(10)
                .background {
                    IBMaterial.bar(in: Circle())
                }
        }
        .padding(16)

        Spacer()

        VStack(spacing: 12) {
            Text("CAMERA")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.75))
                .ibEyebrowTracking()
            IBPrimaryButton(style: .stream)
        }

        Spacer().frame(height: 60)
    }
}
    .preferredColorScheme(.dark)

UIRenderer.render(camera, size: CGSize(width: 390, height: 844),
                   to: "/tmp/ibridge_camera.png")

// MARK: - Trackpad screen

let trackpad = ZStack {
    Color.black

    VStack(spacing: 0) {
        HStack(spacing: 8) {
            IBStatusPill(status: .connected(latencyMs: 24))
            Spacer()
            HStack(spacing: 6) {
                ForEach([0, 1, 2], id: \.self) { i in
                    Image(systemName: ["camera.fill", "hand.point.up.left.fill", "keyboard"][i])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(i == 1 ? .white : .white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background {
                            if i == 1 {
                                IBMaterial.bar(in: Circle())
                            }
                        }
                }
            }
        }
        .padding(16)

        Spacer()

        VStack(spacing: 8) {
            Text("MODE")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.55))
                .ibEyebrowTracking()
            Text("Trackpad")
                .font(IBFont.displayLarge)
                .ibDisplayTracking()
                .foregroundStyle(.white)
            Text("One-finger drag = mouse · Two-finger drag = scroll · Tap = click")
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }

        Spacer()

        HStack(spacing: 8) {
            ForEach([0, 1, 2, 3], id: \.self) { i in
                let symbol = ["⌃", "⌥", "⌘", "⇧"][i]
                let active = i == 2
                Text(symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(active ? .white : .black)
                    .frame(width: 48, height: 48)
                    .background {
                        if active {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [.blue, .blue.opacity(0.85)],
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.white.opacity(0.2))
                            }
                            .shadow(color: .blue.opacity(0.5), radius: 8)
                        } else {
                            IBMaterial.glass(in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 50)
    }
}
    .preferredColorScheme(.dark)

UIRenderer.render(trackpad, size: CGSize(width: 390, height: 844),
                   to: "/tmp/ibridge_trackpad.png")

// MARK: - Keyboard screen

let keyboard = ZStack {
    Color.black

    VStack(spacing: 0) {
        HStack(spacing: 8) {
            IBStatusPill(status: .connected(latencyMs: 18))
            Spacer()
            HStack(spacing: 6) {
                ForEach([0, 1, 2], id: \.self) { i in
                    Image(systemName: ["camera.fill", "hand.point.up.left.fill", "keyboard"][i])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(i == 2 ? .white : .white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background {
                            if i == 2 {
                                IBMaterial.bar(in: Circle())
                            }
                        }
                }
            }
        }
        .padding(16)

        Spacer()

        // Buffer with current typing
        VStack(alignment: .leading, spacing: 4) {
            Text("TYPING INTO MAC")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.45))
                .ibEyebrowTracking()
            Text("Hello from my iPhone")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)

        Spacer()

        // Bottom: keyboard preview with QWERTY layout
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach("qwertyuiop".map { String($0) }, id: \.self) { c in
                    Text(c.uppercased())
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.06))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.08))
                                }
                        }
                }
            }
            HStack(spacing: 4) {
                ForEach("asdfghjkl".map { String($0) }, id: \.self) { c in
                    Text(c.uppercased())
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.06))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.08))
                                }
                        }
                }
            }
            HStack(spacing: 4) {
                Text("⇧")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                    }
                ForEach("zxcvbnm".map { String($0) }, id: \.self) { c in
                    Text(c.uppercased())
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.06))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.08))
                                }
                        }
                }
                Text("⌫")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                    }
            }
            HStack(spacing: 4) {
                Text("123")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 40)
                    .background { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)) }
                Text("space")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)) }
                Text("⏎")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 60, height: 40)
                    .background { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 20)
    }
    .background {
        LinearGradient(colors: [Color(red: 0.10, green: 0.25, blue: 0.55),
                                Color(red: 0.40, green: 0.15, blue: 0.45)],
                       startPoint: .top, endPoint: .bottom)
    }
}
    .preferredColorScheme(.dark)

UIRenderer.render(keyboard, size: CGSize(width: 390, height: 844),
                   to: "/tmp/ibridge_keyboard.png")

// MARK: - Mac control panel + design system showcase

let designSystem = IBDesignSystemShowcase()
UIRenderer.render(designSystem.frame(width: 800, height: 700),
                   size: CGSize(width: 800, height: 700),
                   to: "/tmp/ibridge_design_system.png")

print("Done.")