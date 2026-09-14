import ApplicationServices
import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Foundation
import RemoteCrabCore

/// Shared setup-state detection for the Mac receiver, used by the
/// setup assistant wizard, the menu bar "Finish Setup…" row, and
/// Preferences.
///
/// Everything here is a cheap system query (TCC flag, CoreAudio HAL
/// device list, CoreMediaIO device list) — nothing is cached by the
/// system daemons in a way that would go stale within a session, so a
/// 1 s poll while the wizard is open is both accurate and free.
///
/// Mutation rule: all `@Published` writes happen on the main queue
/// (every caller is a SwiftUI view or the main-run-loop timer).
final class SetupStatus: ObservableObject, @unchecked Sendable {

    @Published private(set) var hasAccessibility: Bool = AXIsProcessTrusted()
    @Published private(set) var cameraDeviceVisible: Bool = false
    @Published private(set) var micDriverInstalled: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // The wizard and the menu row derive camera state from the
        // shared sysex manager; forward its changes so SwiftUI
        // re-renders even though we don't own that state.
        SystemExtensionManager.shared.$activationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        refresh()
    }

    /// Re-run every detection. Called by the wizard's 1 s timer and on
    /// menu-popover open; deliberately NOT an always-on poll — the queries hit
    /// the HAL/CMIO daemons and don't need to run while idle.
    func refresh() {
        hasAccessibility = AXIsProcessTrusted()
        cameraDeviceVisible = cmioDevice(uid: IBCameraDevice.uid) != nil
        micDriverInstalled = halMicDriverInstalled()
    }

    /// The ground truth for "the virtual camera works": the device is
    /// in the CMIO list. Do NOT gate this on the sysex activation state
    /// — that state only reflects requests submitted by THIS process,
    /// and a fresh launch where the registration is already up to date
    /// reports `.unknown` even though the camera is live.
    var cameraReady: Bool {
        cameraDeviceVisible
    }

    /// The two gates the menu bar row cares about: without Accessibility
    /// the trackpad/keyboard don't work; without the camera extension
    /// the webcam doesn't exist.
    var isComplete: Bool {
        hasAccessibility && cameraReady
    }

    // MARK: - Actions (shared with Preferences)

    /// Triggers the system "RemoteCrab would like to control this
    /// computer" prompt. Safe to call repeatedly — macOS shows the
    /// prompt at most once per install; later calls just return the
    /// current state.
    static func requestAccessibility() {
        let opts: NSDictionary = [
            "AXTrustedCheckOptionPrompt" as NSString: kCFBooleanTrue
        ]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openExtensionSettings() {
        // Prefer the Camera Extensions pane; fall back to Login Items &
        // Extensions, then to the Security pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

// MARK: - Shared device detection (CoreMediaIO / CoreAudio C APIs)

/// Locate a CMIO device by its `kCMIODevicePropertyDeviceUID`. Used by
/// `CameraSinkFeeder` (to find the extension's sink stream) and by the
/// setup flow (to detect that "RemoteCrab Camera" is visible).
func cmioDevice(uid: String) -> CMIODeviceID? {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == 0 else {
        return nil
    }
    let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    guard count > 0 else { return nil }
    var devices = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &devices) == 0 else {
        return nil
    }
    for device in devices where cmioDeviceUID(device) == uid {
        return device
    }
    return nil
}

func cmioDeviceUID(_ device: CMIODeviceID) -> String? {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == 0 else { return nil }
    var uid: CFString = "" as NSString
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &uid) == 0 else { return nil }
    return uid as String
}

/// Is the virtual-microphone HAL device present? Querying the device
/// list is more reliable than checking the install path, which the
/// sandbox may hide.
func halMicDriverInstalled() -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return false }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return false }
    return ids.contains { id in
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, $0)
        }
        return status == noErr && (uid as String?) == "com.remotecrab.RemoteCrabMicrophone.device"
    }
}
