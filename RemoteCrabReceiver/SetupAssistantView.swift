import AppKit
import SwiftUI
import RemoteCrabCore

/// First-run setup assistant for the Mac receiver — replaces the old
/// accessibility-only FirstLaunchView.
///
/// Why a wizard: getting every feature working takes four system-level
/// steps that used to be scattered across Preferences (Accessibility
/// grant, sysex approval, the Camera Extensions toggle, the HAL mic
/// driver pkg). This walks through them in order with live status
/// detection — each step checks itself once per second and auto-advances
/// the moment macOS reports it done, so the user never has to guess
/// whether a step "took".
///
/// Accessibility is not skippable (without it the trackpad and keyboard
/// — the core of the product — don't work). The virtual camera and
/// microphone are optional and offer "Skip for now".
struct SetupAssistantView: View {
    @Binding var didComplete: Bool
    @EnvironmentObject private var setupStatus: SetupStatus
    @EnvironmentObject private var sysexManager: SystemExtensionManager

    @State private var step: SetupStep = .welcome
    @State private var skipped: Set<SetupStep> = []
    @State private var showMicPkgMissing = false

    /// Polls while the window is alive; combined with the fact that the
    /// view only exists during setup, this keeps the 1 s queries scoped
    /// to when they're actually useful.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum SetupStep: Int, CaseIterable, Hashable {
        case welcome, accessibility, camera, microphone, done

        var title: String {
            switch self {
            case .welcome:       return IBLocale.Setup.stepWelcome
            case .accessibility: return IBLocale.Setup.stepAccessibility
            case .camera:        return IBLocale.Setup.stepCamera
            case .microphone:    return IBLocale.Setup.stepMicrophone
            case .done:          return IBLocale.Setup.stepDone
            }
        }

        var symbol: String {
            switch self {
            case .welcome:       return "hand.wave"
            case .accessibility: return "accessibility"
            case .camera:        return "camera.fill"
            case .microphone:    return "mic.fill"
            case .done:          return "checkmark.circle"
            }
        }

        /// Steps the user may pass on and finish later from Preferences.
        var isOptional: Bool { self == .camera || self == .microphone }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(IBColor.canvas)
        }
        .frame(width: 640, height: 480)
        .onAppear {
            setupStatus.refresh()
            advanceIfNeeded()
        }
        .onReceive(poll) { _ in
            setupStatus.refresh()
            advanceIfNeeded()
        }
        .alert(IBLocale.MicDriver.install, isPresented: $showMicPkgMissing) {
            Button(IBLocale.Settings.done, role: .cancel) {}
        } message: {
            Text(IBLocale.Setup.micPkgMissing)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(IBLocale.Setup.title)
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.secondary)
                .ibEyebrowTracking()
                .padding(.horizontal, IBSpace.m.pt)
                .padding(.top, IBSpace.l.pt)
                .padding(.bottom, IBSpace.s.pt)

            ForEach(Array(SetupStep.allCases.enumerated()), id: \.element) { _, s in
                sidebarRow(s)
            }

            Spacer()
        }
    }

    private func sidebarRow(_ s: SetupStep) -> some View {
        // A real Button, not onTapGesture: VoiceOver and full keyboard
        // access must be able to jump between steps.
        Button {
            step = s
        } label: {
            HStack(spacing: IBSpace.s.pt) {
                Image(systemName: sidebarIcon(s))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sidebarColor(s))
                    .frame(width: 16, alignment: .center)
                Text(s.title)
                    .font(IBFont.bodySmall)
                    .foregroundStyle(s == step ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, IBSpace.m.pt)
            .padding(.vertical, 6)
            .background {
                if s == step {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .padding(.horizontal, IBSpace.xs.pt)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(s == step ? .isSelected : [])
    }

    private func sidebarIcon(_ s: SetupStep) -> String {
        if isComplete(s) { return "checkmark.circle.fill" }
        if skipped.contains(s) { return "minus.circle" }
        return s == step ? "circle.fill" : "circle"
    }

    private func sidebarColor(_ s: SetupStep) -> Color {
        if isComplete(s) { return IBColor.success }
        if skipped.contains(s) { return IBColor.textTertiary }
        return s == step ? IBColor.accent : IBColor.textTertiary
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: IBSpace.xxxl.pt)

            HStack(spacing: IBSpace.m.pt) {
                Image(systemName: step.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(IBColor.accent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(IBColor.accent.opacity(0.12)))
                Text(step.title)
                    .font(IBFont.titleLarge)
            }

            Spacer().frame(height: IBSpace.l.pt)

            stepBody

            Spacer(minLength: IBSpace.l.pt)

            stepFooter
                .padding(.bottom, IBSpace.xl.pt)
        }
        .padding(.horizontal, IBSpace.xxl.pt)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome:
            bodyText(IBLocale.Setup.welcomeBody)
            bodyText(IBLocale.Setup.welcomeHint)

        case .accessibility:
            statusRow(done: setupStatus.hasAccessibility,
                      doneText: IBLocale.Permission.accessibilityGranted,
                      pendingText: IBLocale.Permission.accessibilityRequired)
            bodyText(IBLocale.Setup.accessibilityWhy)
            if !setupStatus.hasAccessibility {
                numberedHint(IBLocale.Setup.accessibilitySteps)
                captionText(IBLocale.Setup.restartHint)
            }

        case .camera:
            statusRow(done: setupStatus.cameraReady,
                      doneText: IBLocale.Settings.cameraExtensionActiveHint,
                      pendingText: cameraPendingText)
            bodyText(IBLocale.Setup.cameraWhy)
            if !setupStatus.cameraDeviceVisible {
                numberedHint(cameraStepsText)
            }
            captionText(IBLocale.Setup.cameraOptional)

        case .microphone:
            statusRow(done: setupStatus.micDriverInstalled,
                      doneText: IBLocale.MicDriver.installed,
                      pendingText: IBLocale.MicDriver.notInstalled)
            bodyText(IBLocale.MicDriver.footer)
            captionText(IBLocale.Setup.microphoneOptional)

        case .done:
            bodyText(IBLocale.Setup.doneBody)
            summaryRow(IBLocale.Setup.stepAccessibility,
                       ok: setupStatus.hasAccessibility,
                       skipped: false)
            summaryRow(IBLocale.Setup.stepCamera,
                       ok: setupStatus.cameraReady,
                       skipped: skipped.contains(.camera))
            summaryRow(IBLocale.Setup.stepMicrophone,
                       ok: setupStatus.micDriverInstalled,
                       skipped: skipped.contains(.microphone))
        }
    }

    @ViewBuilder
    private var stepFooter: some View {
        switch step {
        case .welcome:
            primaryButton(IBLocale.Setup.begin, symbol: "arrow.right") {
                advance()
            }

        case .accessibility:
            if setupStatus.hasAccessibility {
                primaryButton(IBLocale.Onboarding.nextBtn, symbol: "arrow.right") {
                    advance()
                }
            } else {
                VStack(alignment: .leading, spacing: IBSpace.m.pt) {
                    primaryButton(IBLocale.Setup.grantAccessibility, symbol: "lock.shield") {
                        SetupStatus.requestAccessibility()
                        SetupStatus.openAccessibilitySettings()
                    }
                    secondaryButton(IBLocale.Permission.openSystemSettings) {
                        SetupStatus.openAccessibilitySettings()
                    }
                    secondaryButton(IBLocale.Setup.restartToApply) {
                        SetupStatus.relaunchApp()
                    }
                }
            }

        case .camera:
            VStack(alignment: .leading, spacing: IBSpace.m.pt) {
                cameraAction
                skipButton(.camera)
            }

        case .microphone:
            VStack(alignment: .leading, spacing: IBSpace.m.pt) {
                if !setupStatus.micDriverInstalled {
                    primaryButton(IBLocale.MicDriver.install, symbol: "square.and.arrow.down") {
                        installMicDriver()
                    }
                } else {
                    primaryButton(IBLocale.Onboarding.nextBtn, symbol: "arrow.right") {
                        advance()
                    }
                }
                skipButton(.microphone)
            }

        case .done:
            primaryButton(IBLocale.Setup.finish, symbol: "checkmark") {
                didComplete = true
            }
        }
    }

    // MARK: - Camera step pieces

    /// The camera step has two macOS gates: approve the system extension
    /// (sysex state machine) and flip the Camera Extensions switch
    /// (device becomes visible). The pending text says which gate we're
    /// waiting on.
    private var cameraPendingText: String {
        switch sysexManager.activationState {
        case .awaitingApproval: return IBLocale.Setup.cameraAwaiting
        case .active:           return IBLocale.Settings.sysexActive
        case .failed:           return IBLocale.Settings.sysexFailed
        default:                return IBLocale.Settings.sysexNotInstalled
        }
    }

    private var cameraStepsText: String {
        switch sysexManager.activationState {
        case .active:           return IBLocale.Setup.cameraSteps
        case .awaitingApproval: return IBLocale.Setup.cameraAwaiting
        default:                return IBLocale.Setup.cameraActivateSteps
        }
    }

    @ViewBuilder
    private var cameraAction: some View {
        switch sysexManager.activationState {
        case .active:
            // Extension approved; the remaining step is the user's
            // toggle in System Settings, so deep-link there.
            primaryButton(IBLocale.Permission.openSystemSettings, symbol: "gear") {
                SetupStatus.openExtensionSettings()
            }
        case .awaitingApproval:
            primaryButton(IBLocale.Permission.openSystemSettings, symbol: "gear") {
                SetupStatus.openExtensionSettings()
            }
        case .repairing:
            HStack(spacing: IBSpace.s.pt) {
                ProgressView().controlSize(.small)
                Text(IBLocale.Settings.sysexRepairing)
                    .font(IBFont.bodySmall)
                    .foregroundStyle(.secondary)
            }
        case .unknown, .notInstalled, .failed:
            primaryButton(IBLocale.Settings.enableCameraExtension, symbol: "camera.badge.clock") {
                sysexManager.activate()
            }
        }
    }

    // MARK: - Building blocks

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(IBFont.bodyMedium)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, IBSpace.m.pt)
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(IBFont.caption)
            .foregroundStyle(IBColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, IBSpace.s.pt)
    }

    /// Manual-operation hint, styled like a numbered instruction card.
    private func numberedHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: IBSpace.s.pt) {
            Image(systemName: "list.number")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(text)
                .font(IBFont.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(IBSpace.m.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                .strokeBorder(IBColor.borderRegular, lineWidth: 1)
        }
        .padding(.bottom, IBSpace.m.pt)
    }

    private func statusRow(done: Bool, doneText: String, pendingText: String) -> some View {
        HStack(spacing: IBSpace.s.pt) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(done ? IBColor.success : IBColor.warning)
                .accessibilityHidden(true)
            Text(done ? doneText : pendingText)
                .font(IBFont.bodySmall)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, IBSpace.m.pt)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                .strokeBorder(IBColor.borderRegular, lineWidth: 1)
        }
        .padding(.bottom, IBSpace.m.pt)
    }

    private func summaryRow(_ title: String, ok: Bool, skipped: Bool) -> some View {
        HStack(spacing: IBSpace.s.pt) {
            Image(systemName: ok ? "checkmark.circle.fill"
                                 : (skipped ? "minus.circle" : "exclamationmark.circle"))
                .font(.system(size: 12))
                .foregroundStyle(ok ? IBColor.success
                                    : (skipped ? IBColor.textTertiary : IBColor.warning))
            Text(title)
                .font(IBFont.bodySmall)
                .foregroundStyle(.primary)
            Spacer()
            Text(ok ? IBLocale.Settings.done
                    : (skipped ? IBLocale.Setup.skipped : IBLocale.Setup.pending))
                .font(IBFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(IBFont.bodyMedium.weight(.semibold))
            .padding(.horizontal, IBSpace.l.pt)
            .padding(.vertical, 9)
            .background { Capsule().fill(Color.accentColor) }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(IBFont.bodySmall)
            .foregroundStyle(.secondary)
    }

    private func skipButton(_ s: SetupStep) -> some View {
        Button(IBLocale.Setup.skipForNow) {
            skipped.insert(s)
            advance()
        }
        // Bordered on purpose: plain tertiary text read as "disabled"
        // and users reported being trapped on the step.
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Flow control

    private func isComplete(_ s: SetupStep) -> Bool {
        switch s {
        case .welcome:       return step != .welcome
        case .accessibility: return setupStatus.hasAccessibility
        case .camera:        return setupStatus.cameraReady
        case .microphone:    return setupStatus.micDriverInstalled
        case .done:          return false
        }
    }

    private func advance() {
        guard let next = SetupStep(rawValue: step.rawValue + 1) else { return }
        step = next
        advanceIfNeeded()
    }

    /// Called after every poll: when the current step completes itself
    /// (the user granted a permission in System Settings while the
    /// wizard sat open), move on automatically. Never advances *past*
    /// the welcome or done steps — those are explicit user actions.
    private func advanceIfNeeded() {
        while step != .welcome && step != .done && isComplete(step) {
            guard let next = SetupStep(rawValue: step.rawValue + 1) else { return }
            step = next
        }
    }

    // MARK: - Mic driver install

    /// One-click install: open the signed pkg shipped inside the app.
    /// Installer.app takes over and asks for admin authorization.
    private func installMicDriver() {
        if let pkg = Bundle.main.url(forResource: "RemoteCrabMicrophone", withExtension: "pkg") {
            NSWorkspace.shared.open(pkg)
        } else {
            showMicPkgMissing = true
        }
    }
}
