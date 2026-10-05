import AppKit
import CoreGraphics
import os
import RemoteCrabCore

/// Executes IBSystemCommand frames from the iPhone. Volume / brightness
/// / media keys all go through system-defined CGEvents (the same path
/// the physical keyboard's media keys use — no extra entitlements, the
/// app's existing Accessibility grant covers event posting). App/URL
/// launch goes through NSWorkspace.
enum SystemCommandHandler {

    private static let log = Logger(subsystem: "com.remotecrab", category: "syscmd")

    // IOKit ev_keymap.h values.
    private static let nxSoundUp: Int32 = 0
    private static let nxSoundDown: Int32 = 1
    private static let nxBrightnessUp: Int32 = 2
    private static let nxBrightnessDown: Int32 = 3
    private static let nxMute: Int32 = 7
    private static let nxPlay: Int32 = 16
    private static let nxNext: Int32 = 17
    private static let nxPrevious: Int32 = 18

    /// Execute the command and report whether it actually did anything.
    ///
    /// Returns the `IBCommandResult.status` the receiver sends back. It used to
    /// return `Void` and the caller replied `ok` unconditionally, so a
    /// `launchApp` for a missing bundle id — which `NSWorkspace` refuses — told
    /// the phone the launch had succeeded. That status is the phone's only
    /// failure signal (`CaptureEngine.resolveCommand`), so the "say why a
    /// command did nothing" channel was dead for exactly the command it was
    /// added for.
    ///
    /// The media/volume/brightness keys are posted best-effort: they are
    /// step-based with no read-back channel, so `.ok` means "posted".
    static func handle(_ command: IBSystemCommand) -> IBCommandResult.Status {
        switch command.command {
        case .volumeUp:       postSystemKey(nxSoundUp);       return .ok
        case .volumeDown:     postSystemKey(nxSoundDown);     return .ok
        case .volumeMute:     postSystemKey(nxMute);          return .ok
        case .brightnessUp:   postSystemKey(nxBrightnessUp);  return .ok
        case .brightnessDown: postSystemKey(nxBrightnessDown); return .ok
        case .mediaPlayPause: postSystemKey(nxPlay);          return .ok
        case .mediaNext:      postSystemKey(nxNext);          return .ok
        case .mediaPrevious:  postSystemKey(nxPrevious);      return .ok
        case .launchApp:
            guard let bundleID = command.argument else {
                log.error("launchApp with no bundle id")
                return .failed
            }
            let ok = NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID,
                                                          options: [],
                                                          additionalEventParamDescriptor: nil,
                                                          launchIdentifier: nil)
            if !ok {
                log.error("launchApp failed: \(bundleID, privacy: .public)")
                return .failed
            }
            return .ok
        case .openURL:
            guard let raw = command.argument, let url = URL(string: raw) else {
                log.error("openURL with no/invalid url")
                return .failed
            }
            return NSWorkspace.shared.open(url) ? .ok : .failed
        case .showDesktop:
            showDesktop()
            return .ok
        }
    }

    /// Reveal the desktop: hide EVERY regular app — **including the one the
    /// user is currently looking at**. The hide is what uncovers the desktop.
    /// Two old mistakes: skipping the active app (`!$0.isActive`) left the
    /// current window on screen, and `finder.activate()` could raise a Finder
    /// window over the desktop. Hiding everything (Finder included) leaves the
    /// wallpaper + desktop icons and nothing else — Win+D semantics.
    private static func showDesktop() {
        let myBundle = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && !app.isTerminated
            && !app.isHidden
            && app.bundleIdentifier != myBundle {
            app.hide()
        }
        log.info("showDesktop requested (all apps hidden)")
    }

    /// Post one press+release of a system-defined (media) key.
    private static func postSystemKey(_ key: Int32) {
        postSystemKey(key, down: true)
        postSystemKey(key, down: false)
    }

    private static func postSystemKey(_ key: Int32, down: Bool) {
        let flags: UInt = down ? 0xA00 : 0xB00
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: SystemKeyEncoder.data1(key: key, down: down),
            data2: -1
        )?.cgEvent else { return }
        event.post(tap: .cghidEventTap)
    }
}
