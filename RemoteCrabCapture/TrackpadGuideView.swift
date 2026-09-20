import SwiftUI
import RemoteCrabCore

/// The full trackpad gesture guide. Presented as a sheet (first run +
/// re-openable from the top-bar menu) rather than an in-surface overlay,
/// so nothing — the dock, the hold-to-talk capsule — can cover its
/// bottom row.
struct TrackpadGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private typealias Row = (symbol: String, text: String)

    private var groups: [(title: String, rows: [Row])] {
        [
            (IBLocale.Coach.sectionMove, [
                ("hand.draw", IBLocale.Coach.dragMove),
                ("hand.tap", IBLocale.Coach.tapClick)
            ]),
            (IBLocale.Coach.sectionScroll, [
                ("arrow.up.and.down", IBLocale.Coach.twoFingerScroll),
                ("cursorarrow.click.2", IBLocale.Coach.twoFingerRightClick),
                ("arrow.up.left.and.arrow.down.right", IBLocale.Coach.pinchZoom)
            ]),
            (IBLocale.Coach.sectionDrag, [
                ("hand.draw", IBLocale.Coach.doubleTapHoldDrag),
                ("arrow.left.and.right", IBLocale.Coach.clutchDrag)
            ]),
            (IBLocale.Coach.sectionFingers, [
                ("hand.point.up", IBLocale.Coach.threeFingerTap),
                ("rectangle.3.group", IBLocale.Coach.threeFingerSwipe),
                ("hand.point.up.braille", IBLocale.Coach.forceClick)
            ]),
            (IBLocale.Coach.sectionKeys, [
                ("command", IBLocale.Coach.modifierBar),
                ("shift", IBLocale.Coach.shiftSelect),
                ("delete.left", IBLocale.Coach.quickKeys)
            ])
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IBSpace.l.pt) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(IBSpace.l.pt)
            }
            .navigationTitle(IBLocale.Coach.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.Coach.dismiss) { dismiss() }
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
            Spacer(minLength: 0)
        }
    }
}
