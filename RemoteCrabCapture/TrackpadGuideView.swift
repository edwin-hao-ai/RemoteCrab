import SwiftUI
import RemoteCrabCore

/// The complete gesture reference.
///
/// One scroll rather than a segmented control: two pages behind a switch
/// *hides* content, and the whole point of adding the mirror section is that
/// a reader can finish the thing. Each surface is a labelled section instead,
/// so "three fingers" is never ambiguous — it means middle-click under
/// Touchpad and free panning under App window mirror, and the reader can
/// see which is which without being told.
///
/// Opened from the mirror it scrolls to the mirror section; opened from the
/// menu it starts at the trackpad. Nothing is behind a tap either way.
struct TrackpadGuideView: View {
    /// Which section to reveal first.
    enum Surface: Hashable {
        case trackpad
        case mirror

        var heading: String {
            switch self {
            case .trackpad: return IBLocale.Coach.surfaceTrackpad
            case .mirror: return IBLocale.Coach.surfaceMirror
            }
        }

        var icon: String {
            switch self {
            case .trackpad: return "hand.point.up.left.fill"
            case .mirror: return "rectangle.on.rectangle.angled"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let surface: Surface
    /// Which OS owns the session. **Required, no default** — the reference
    /// is read mid-session, and a row that names ⌘ or Mission Control to a
    /// PC user describes a machine they are not holding. Same reasoning as
    /// `IBModifierBar.platform`: a default here would make the wrong
    /// wording the silent default rather than a visible mistake.
    let platform: IBModifierBar.PeerPlatform

    init(surface: Surface = .trackpad, platform: IBModifierBar.PeerPlatform) {
        self.surface = surface
        self.platform = platform
    }

    private typealias Row = (symbol: String, text: String)

    private var trackpadGroups: [(title: String, rows: [Row])] {
        [
            (IBLocale.Coach.sectionMove, [
                ("hand.draw", IBLocale.Coach.dragMove),
                ("hand.tap", IBLocale.Coach.tapClick)
            ]),
            (IBLocale.Coach.sectionScroll, [
                ("arrow.up.and.down", IBLocale.Coach.twoFingerScroll),
                ("cursorarrow.click.2", IBLocale.Coach.twoFingerRightClick),
                ("arrow.up.left.and.arrow.down.right", IBLocale.Coach.pinchZoom(for: platform))
            ]),
            (IBLocale.Coach.sectionDrag, [
                ("hand.draw", IBLocale.Coach.doubleTapHoldDrag),
                ("arrow.left.and.right", IBLocale.Coach.clutchDrag)
            ]),
            (IBLocale.Coach.sectionFingers, [
                ("hand.point.up", IBLocale.Coach.threeFingerTap),
                ("rectangle.3.group", IBLocale.Coach.threeFingerSwipe(for: platform)),
                ("hand.point.up.braille", IBLocale.Coach.forceClick)
            ]),
            (IBLocale.Coach.sectionKeys, [
                (IBLocale.Coach.modifierSymbol(for: platform), IBLocale.Coach.modifierBar(for: platform)),
                ("shift", IBLocale.Coach.shiftSelect),
                ("delete.left", IBLocale.Coach.quickKeys)
            ])
        ]
    }

    private var mirrorGroups: [(title: String, rows: [Row])] {
        [
            (IBLocale.Coach.mirrorSectionTap, [
                ("hand.tap", IBLocale.Coach.mirrorTapClick),
                ("hand.draw", IBLocale.Coach.mirrorDrag(for: platform)),
                ("cursorarrow.click.2", IBLocale.Coach.mirrorRightClick)
            ]),
            (IBLocale.Coach.mirrorSectionScroll, [
                ("arrow.up.and.down", IBLocale.Coach.mirrorScroll(for: platform))
            ]),
            (IBLocale.Coach.mirrorSectionMove, [
                ("arrow.left.and.right", IBLocale.Coach.mirrorPan),
                ("arrow.up.left.and.arrow.down.right", IBLocale.Coach.mirrorPinch),
                ("hand.tap.fill", IBLocale.Coach.mirrorDoubleTapZoom)
            ]),
            (IBLocale.Coach.mirrorSectionThree, [
                ("rectangle.3.group", IBLocale.Coach.mirrorThreeFingerPan)
            ])
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IBSpace.l.pt) {
                    section(Surface.trackpad, groups: trackpadGroups)
                    Divider().padding(.vertical, IBSpace.s.pt)
                    section(Surface.mirror, groups: mirrorGroups)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(IBSpace.l.pt)
            }
            // Start on the section the caller cares about: the mirror
            // section is last, so `.bottom` reveals it and the reader can
            // scroll UP for the trackpad — nothing is hidden either way.
            // Declarative, where `proxy.scrollTo` in a `.task` needs the
            // target to have been measured first and silently no-ops if it
            // has not (a magic sleep standing in for layout is a trap).
            .defaultScrollAnchor(surface == .mirror ? .bottom : .top)
            .navigationTitle(IBLocale.Coach.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.Coach.dismiss) { dismiss() }
                }
            }
        }
    }

    private func section(_ surface: Surface,
                         groups: [(title: String, rows: [Row])]) -> some View {
        VStack(alignment: .leading, spacing: IBSpace.m.pt) {
            Label(surface.heading, systemImage: surface.icon)
                .font(IBFont.titleMedium)
                .foregroundStyle(IBColor.accent)
                .padding(.bottom, IBSpace.xs.pt)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: IBSpace.s.pt) {
                    Text(group.title)
                        .font(IBFont.eyebrowMono)
                        .ibEyebrowTracking()
                        .foregroundStyle(IBColor.textSecondary)
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        line(symbol: row.symbol, text: row.text)
                    }
                }
            }
        }
    }

    private func line(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: IBSpace.m.pt) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(IBColor.accent)
                .frame(width: 26, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(IBFont.bodyMedium)
                .foregroundStyle(IBColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}