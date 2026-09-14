import SwiftUI
import RemoteCrabCore

/// Sample camera content shown when Demo Mode is on, so App Review can
/// exercise the camera surface without a Mac receiver. Clearly
/// watermarked "DEMO" so it is never mistaken for a live feed.
struct DemoCameraView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.42, blue: 0.85),
                        Color(red: 0.70, green: 0.30, blue: 0.72)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .hueRotation(.degrees((time.truncatingRemainder(dividingBy: 16)) * 22))

                VStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(IBLocale.Demo.badge)
                        .font(IBFont.eyebrowMono)
                        .ibEyebrowTracking()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background { Capsule().fill(.black.opacity(0.35)) }
                    Text(Date(), style: .time)
                        .font(IBFont.monoMedium)
                        .foregroundStyle(.white.opacity(0.9))
                    Text(IBLocale.Demo.explainer)
                        .font(IBFont.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 44)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
