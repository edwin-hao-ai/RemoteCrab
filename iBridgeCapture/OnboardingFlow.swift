import SwiftUI
import AVFoundation
import iBridgeCore

/// First-launch onboarding for iBridge Capture.
///
/// Three swipeable pages, each explaining a part of the product:
///
///   1. **Hero** — what iBridge does, brand mark, "Get Started"
///   2. **Permissions** — why we need camera / mic / local network
///   3. **Pair with Mac** — how to install the Mac app and what to do next
///
/// After page 3 the user enters the **PermissionRequestFlow** which
/// actually asks for the permissions one at a time. Only after every
/// permission has been resolved (granted or denied) does the main
/// `ContentView` appear.
struct OnboardingFlow: View {
    @Binding var hasSeenOnboarding: Bool
    @State private var page: Int = 0

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    OnboardingPage.hero(onContinue: { advance() })
                        .tag(0)
                    OnboardingPage.permissions(onContinue: { advance() })
                        .tag(1)
                    OnboardingPage.pairMac(onContinue: { advance() })
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(.container, edges: .top)

                PageIndicator(count: 3, current: page)
                    .padding(.bottom, IBSpace.m.pt)

                actionRow
                    .padding(.horizontal, IBSpace.xl.pt)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        IBGradient.canvasDark
            .ignoresSafeArea()
    }

    private func advance() {
        withAnimation(IBAnimation.standard) {
            if page < 2 {
                page += 1
            } else {
                hasSeenOnboarding = true
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if page < 2 {
            HStack {
                Button(IBLocale.Onboarding.skip) { hasSeenOnboarding = true }
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            Spacer()
            Button {
                advance()
            } label: {
                HStack(spacing: 6) {
                    Text(IBLocale.Onboarding.nextBtn)
                        .font(IBFont.bodyMedium.weight(.semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                hasSeenOnboarding = true
            } label: {
                HStack(spacing: 6) {
                    Text(IBLocale.Onboarding.allowAndConnect)
                        .font(IBFont.bodyMedium.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    Capsule().fill(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Pages

struct OnboardingPage: View {
    let kind: Kind
    let onContinue: () -> Void

    enum Kind {
        case hero
        case permissions
        case pairMac
    }

    init(_ kind: Kind, onContinue: @escaping () -> Void) {
        self.kind = kind
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 40)

            hero
                .frame(maxHeight: .infinity)

            VStack(spacing: IBSpace.m.pt) {
                Text(title)
                    .font(IBFont.displayMedium)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, IBSpace.xxl.pt)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 40)
        }
    }

    private var title: String {
        switch kind {
        case .hero:        return IBLocale.Onboarding.heroTitle
        case .permissions: return IBLocale.Onboarding.permissionsTitle
        case .pairMac:     return IBLocale.Onboarding.pairTitle
        }
    }

    private var subtitle: String {
        switch kind {
        case .hero:
            return IBLocale.Onboarding.heroBody
        case .permissions:
            return IBLocale.Onboarding.permissionsBody
        case .pairMac:
            return IBLocale.Onboarding.pairBody
        }
    }

    @ViewBuilder
    private var hero: some View {
        switch kind {
        case .hero:
            HeroIllustration()
        case .permissions:
            PermissionsIllustration()
        case .pairMac:
            PairMacIllustration()
        }
    }

    // Hero: animated iPhone → Mac data flow
    @ViewBuilder
    static func hero(onContinue: @escaping () -> Void) -> some View {
        OnboardingPage(.hero, onContinue: onContinue)
    }

    // Permissions: 3 stacked cards for the 3 permissions
    @ViewBuilder
    static func permissions(onContinue: @escaping () -> Void) -> some View {
        OnboardingPage(.permissions, onContinue: onContinue)
    }

    // Pair: iPhone + Mac side by side with wave between
    @ViewBuilder
    static func pairMac(onContinue: @escaping () -> Void) -> some View {
        OnboardingPage(.pairMac, onContinue: onContinue)
    }
}

// MARK: - Hero illustration

private struct HeroIllustration: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let r = 80 + CGFloat(i) * 40 + phase * 10
                Circle()
                    .stroke(Color.accentColor.opacity(0.6 - Double(i) * 0.15),
                            lineWidth: 2)
                    .frame(width: r, height: r)
                    .scaleEffect(1.0 + sin(phase * 2 + Double(i)) * 0.05)
            }

            // iPhone + Mac in the center
            HStack(spacing: 24) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: "macbook.gen2")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(.white)
            }
        }
        .frame(height: 320)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }
}

// MARK: - Permissions illustration

private struct PermissionsIllustration: View {
    var body: some View {
        VStack(spacing: 18) {
            permissionCard(icon: "camera.fill",
                           title: "Camera",
                           description: "Live iPhone feed to your Mac")
            permissionCard(icon: "mic.fill",
                           title: "Microphone",
                           description: "Stream iPhone mic to Mac speakers")
            permissionCard(icon: "wifi",
                           title: "Local Network",
                           description: "Discover & connect to your Mac")
        }
        .padding(.horizontal, IBSpace.xxl.pt)
        .frame(height: 320)
    }

    private func permissionCard(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(Color.accentColor.opacity(0.18))
                        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .background {
            IBMaterial.glass(in: RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
        }
    }
}

// MARK: - Pair Mac illustration

private struct PairMacIllustration: View {
    @State private var dotPhase: CGFloat = 0

    var body: some View {
        HStack(spacing: 32) {
            deviceColumn(icon: "iphone.gen3", label: "iPhone", side: .left)
            wifiBridge
            deviceColumn(icon: "macbook.gen2", label: "Mac", side: .right)
        }
        .frame(height: 320)
        .padding(.horizontal, 24)
    }

    private enum Side { case left, right }

    private func deviceColumn(icon: String, label: String, side: Side) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
            Text(label)
                .font(IBFont.titleMedium)
                .foregroundStyle(.white)
            Text(side == .left ? IBLocale.App.captureName : IBLocale.App.receiverName)
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var wifiBridge: some View {
        VStack(spacing: 14) {
            Text(IBLocale.Onboarding.sameWiFi)
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.5))
                .ibEyebrowTracking()
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.4 + Double(i) * 0.2))
                        .frame(width: 6 + CGFloat(i) * 6, height: 3)
                }
            }
            .scaleEffect(1.0 + sin(dotPhase * 2) * 0.2)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
                .rotationEffect(.degrees(dotPhase * 360))
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                dotPhase = 1
            }
        }
    }
}

// MARK: - Page indicator

private struct PageIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.white : Color.white.opacity(0.25))
                    .frame(width: i == current ? 20 : 6, height: 6)
                    .animation(IBAnimation.snappy, value: current)
            }
        }
    }
}
