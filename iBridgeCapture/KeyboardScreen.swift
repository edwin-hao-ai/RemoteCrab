import SwiftUI
import UIKit
import iBridgeCore

/// Keyboard mode — full QWERTY layout with press animations and a
/// live preview of what's being typed on the Mac.
struct KeyboardScreen: View {
    @EnvironmentObject private var engine: CaptureEngine
    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    @State private var typedText: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.12),
                    Color(red: 0.15, green: 0.06, blue: 0.20)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                header
                previewCard
                qwerty
                modifierBar
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .onChange(of: typedText) { _, new in
            engine.sendKey(KeyEvent(action: .text, text: new))
        }
        .onAppear {
            inputFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "keyboard")
                .foregroundStyle(.white.opacity(0.7))
            Text("KEYBOARD MODE")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.7))
                .ibEyebrowTracking()
            Spacer()
            Text("⌨ typing on Mac")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.45))
                .ibEyebrowTracking()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.white.opacity(0.5))
                Text("ON YOUR MAC")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.5))
                    .ibEyebrowTracking()
                Spacer()
                Text("\(typedText.count) chars")
                    .font(IBFont.monoSmall)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(typedText.isEmpty ? "Start typing…" : typedText)
                .font(IBFont.titleMedium)
                .foregroundStyle(typedText.isEmpty ? .white.opacity(0.35) : .white)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    // MARK: - QWERTY

    private var qwerty: some View {
        VStack(spacing: 6) {
            rowOf(["q","w","e","r","t","y","u","i","o","p"], spacing: 4)
            rowOf(["a","s","d","f","g","h","j","k","l"], spacing: 4)
                .padding(.leading, 18)
            row3
            row4
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }

    private func rowOf(_ chars: [String], spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(chars, id: \.self) { ch in
                key(ch.uppercased(), flex: 1)
            }
        }
    }

    private var row3: some View {
        HStack(spacing: 4) {
            special("⇧", width: 50) {}
            rowOf(["z","x","c","v","b","n","m"], spacing: 4)
                .layoutPriority(1)
            special("⌫", width: 50) {}
        }
    }

    private var row4: some View {
        HStack(spacing: 4) {
            special("123", width: 50) {}
            Button {
                inputFocused = true
            } label: {
                Text("space")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                            }
                    }
            }
            .buttonStyle(.plain)
            special("⏎", width: 70) {}
        }
    }

    private func key(_ label: String, flex: CGFloat) -> some View {
        Button {
            // Touch typing key — feed the system keyboard below.
            inputFocused = true
        } label: {
            Text(label)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }

    private func special(_ label: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: width, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Modifier bar

    private var modifierBar: some View {
        HStack(spacing: 6) {
            ForEach([IBModifierBar.Modifier.control, .option, .command, .shift], id: \.self) { m in
                Button {
                    if modifiers.contains(m) { modifiers.remove(m) }
                    else { modifiers.insert(m) }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(modifiers.contains(m) ? .white : .white.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            if modifiers.contains(m) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .shadow(color: Color.accentColor.opacity(0.4), radius: 6)
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}