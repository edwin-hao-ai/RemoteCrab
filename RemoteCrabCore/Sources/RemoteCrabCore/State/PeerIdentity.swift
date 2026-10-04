import Foundation

/// Everything the phone knows about *whose computer it is talking to*.
///
/// ## Why one type and not four arrays
///
/// These four lists — the running apps, the windows, whether window capture
/// is permitted, and the launchable apps — each arrive as a separate wire
/// frame from the computer that currently owns the session. They were four
/// independent `@Published` arrays on `CaptureEngine`, and the ownership
/// teardown reset eighteen other fields while resetting none of them.
///
/// The consequence was not cosmetic. The phone never forgot the previous
/// computer: switching from the Mac to Windows left the Mac's frontmost app
/// in place, and the context sheet named it (on a Chinese macOS that string
/// is literally `访达`), the launcher offered the Mac's bundle ids, and the
/// window picker offered a Mac window. `installedAppsGate.reset()` made it
/// worse rather than better — it cleared the *phase* while the *list*
/// survived, so the gate could report "answered" about a list belonging to
/// a computer that had left.
///
/// So the state that describes an owner is one value, it has exactly one
/// operation that ends it, and the reads cannot answer without it:
///
/// ```swift
/// var peer = PeerIdentity()
/// peer.install(apps: list)     // a frame arrives
/// peer.clear()                 // the computer goes away — ALL of it
/// peer.frontmostApp            // nil, because nothing is installed
/// ```
///
/// ## What this deliberately does not hold
///
/// The rendered image caches (app icons, window thumbnails) stay on
/// `CaptureEngine`. They are `UIImage`, they are derived from these lists
/// rather than part of the identity, and keeping them here would drag UIKit
/// into the core package for no invariant to protect.
///
/// Pure and `Codable`-free on purpose, like `MacPairingStore` and
/// `ScreenZoomState`: the bug was untestable state, and it stays testable.
public struct PeerIdentity: Equatable, Sendable {

    /// The computer's running applications. Empty until an `appList` frame
    /// (`0x0C`) arrives.
    public private(set) var apps: [IBAppInfo] = []

    /// Its top-level windows, from `windowList` (`0x18`).
    public private(set) var windows: [IBWindowInfo] = []

    /// Whether that computer is permitted to capture window contents. It
    /// belongs to the *window list*, so it is replaced with it and cleared
    /// with it — a stale `true` offers a mirror affordance to a peer that
    /// cannot honour it.
    public private(set) var windowsCanCapture: Bool = false

    /// Launchable applications, from `installedApps` (`0x21`).
    public private(set) var installedApps: [IBInstalledApp] = []

    public init() {}

    /// No computer is on the other end. `CaptureEngine` calls this from the
    /// one place a new computer takes the session, so a forgotten field
    /// cannot outlive its owner.
    public var isEmpty: Bool {
        apps.isEmpty && windows.isEmpty && installedApps.isEmpty
    }

    /// The app whose suite the context sheet shows.
    ///
    /// `nil` unless a list has been installed *since the last `clear()`*.
    /// That is the whole bug fixed as a type rather than as a teardown
    /// someone has to remember: there is no path from "the Mac left" to
    /// "the Mac's app is still the frontmost one".
    public var frontmostApp: IBAppInfo? {
        apps.first { $0.isActive }
    }

    // MARK: - Installing what a computer said about itself

    /// A newer `appList` **replaces** the previous one. It does not merge:
    /// two computers' app lists concatenated is exactly the state this type
    /// exists to prevent, and a stale entry would keep winning `first(where:)`.
    public mutating func install(apps list: [IBAppInfo]) {
        apps = list
    }

    /// A newer `windowList` replaces the previous one, capability included.
    public mutating func install(windows list: [IBWindowInfo], canCapture: Bool) {
        windows = list
        windowsCanCapture = canCapture
    }

    public mutating func install(installedApps list: [IBInstalledApp]) {
        installedApps = list
    }

    /// Drop every window belonging to an app — it quit, so its windows must
    /// stop being offered. Scoped on purpose: the capability flag belongs to
    /// the list, not to the app.
    public mutating func forgetWindow(appId: String) {
        windows.removeAll { $0.appId == appId }
    }

    // MARK: - Ending it

    /// The computer is gone. One operation, every field, no exceptions.
    ///
    /// Named rather than inlined at the call site so that "did we forget
    /// something?" has an answer you can read: this list is the list.
    public mutating func clear() {
        apps = []
        windows = []
        windowsCanCapture = false
        installedApps = []
    }
}