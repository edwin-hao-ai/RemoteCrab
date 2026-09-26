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

    static func handle(_ command: IBSystemCommand) {
        switch command.command {
        case .volumeUp:       postSystemKey(nxSoundUp)
        case .volumeDown:     postSystemKey(nxSoundDown)
        case .volumeMute:     postSystemKey(nxMute)
        case .brightnessUp:   postSystemKey(nxBrightnessUp)
        case .brightnessDown: postSystemKey(nxBrightnessDown)
        case .mediaPlayPause: postSystemKey(nxPlay)
        case .mediaNext:      postSystemKey(nxNext)
        case .mediaPrevious:  postSystemKey(nxPrevious)
        case .launchApp:
            if let bundleID = command.argument {
                let ok = NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID,
                                                              options: [],
                                                              additionalEventParamDescriptor: nil,
                                                              launchIdentifier: nil)
                if !ok { log.error("launchApp failed: \(bundleID, privacy: .public)") }
            }
        case .openURL:
            if let raw = command.argument, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .showDesktop:
            showDesktop()
        }
    }

    /// Reveal the desktop: hide every other regular app (so nothing
    /// covers it) and bring Finder to the front. The hide is the part
    /// that actually uncovers it — activating Finder alone would only
    /// raise a Finder window.
    private static func showDesktop() {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isActive && !$0.isTerminated }
            .forEach { $0.hide() }
        if let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) {
            finder.activate()
        }
        log.info("showDesktop requested")
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
