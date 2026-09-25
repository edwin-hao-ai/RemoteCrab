import SwiftUI

/// The shared bottom shortcut bar used by the trackpad and the app-window
/// mirror (and available to any surface): a pinned frontmost-app context
/// chip, then ONE horizontally-scrollable row of keys with the lockable
/// modifier bar inline and `,` / `.` punctuation.
///
/// One implementation so the surfaces stay visually and behaviourally
/// consistent — the mirror used to ship a bespoke two-row bar that didn't
/// scroll and had no context-sheet entry.
public struct IBShortcutBar: View {

    @Binding private var activeModifiers: Set<IBModifierBar.Modifier>
    private let contextTitle: String?
    private let onContext: (() -> Void)?
    private let onKey: (KeyEvent) -> Void
    private let onModifierKey: ((UInt16, Bool) -> Void)?

    public init(activeModifiers: Binding<Set<IBModifierBar.Modifier>>,
                contextTitle: String? = nil,
                onContext: (() -> Void)? = nil,
                onKey: @escaping (KeyEvent) -> Void,
                onModifierKey: ((UInt16, Bool) -> Void)? = nil) {
        self._activeModifiers = activeModifiers
        self.contextTitle = contextTitle
        self.onContext = onContext
        self.onKey = onKey
        self.onModifierKey = onModifierKey
    }

    public var body: some View {
        HStack(spacing: IBSpace.s.pt) {
            // Pinned OUTSIDE the ScrollView so it never scrolls away.
            if let contextTitle {
                contextChip(contextTitle)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: IBSpace.s.pt) {
                    // ⏎/⌫ lead the row: after voice dictation the next
                    // reach is always "edit" or "send".
                    key(symbol: "return", accessibility: IBLocale.A11y.returnKey, keycode: 36, prominent: true)
                    key(symbol: "delete.left", accessibility: IBLocale.A11y.deleteKey, keycode: 51)
                    key(text: "esc", accessibility: IBLocale.A11y.escapeKey, keycode: 53)
                    Rectangle()
                        .fill(IBColor.borderSubtle)
                        .frame(width: 1, height: 28)
                    IBModifierBar(activeModifiers: $activeModifiers, onModifierKey: onModifierKey)
                    key(text: ",", accessibility: IBLocale.A11y.commaKey, keycode: 43)
                    key(text: ".", accessibility: IBLocale.A11y.periodKey, keycode: 47)
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func send(_ keycode: UInt16) {
        onKey(KeyEvent(action: .down, keycode: keycode))
        onKey(KeyEvent(action: .up, keycode: keycode))
    }

    private func key(symbol: String? = nil, text: String? = nil,
                     accessibility: String, keycode: UInt16,
                     prominent: Bool = false) -> some View {
        Button {
            send(keycode)
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

    private func contextChip(_ title: String) -> some View {
        Button {
            onContext?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
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
}
