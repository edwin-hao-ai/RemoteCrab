import Foundation

/// What to do with the capture listener when the app returns to the
/// foreground.
///
/// ## Why this is a policy and not a flag check
///
/// `handleDidBecomeActive` rebuilt the listener only when
/// `!BackgroundKeepAlive.shared.isActive` — it asked "is the keep-alive
/// running?" and used the answer as a proxy for "is the listener alive?".
/// On iOS 26 the two came apart. Measured on iPhone 14, 2026-10-09:
///
///     [keepalive] session playback active          ← keep-alive said it was up
///     … backgrounded …
///     [main-stall] main thread busy 217318ms        ← the app was suspended
///     [hs] listener failed: -65569 DefunctConnection ← the listener had died
///
/// Yet `isActive` was still `true`, so the dead listener was **never rebuilt**.
/// The phone kept encoding video while `192.168.31.148:8765` was `CLOSED` and
/// Bonjour was empty: it produced a picture nobody could receive, until the
/// user manually toggled streaming.
///
/// The fix is to ask the listener's **own** state. `isActive` is a software
/// flag set by `start()` and cleared only by `stop()`; it says nothing about
/// whether the socket survived suspension.
///
/// The `linkAlive` guard is kept: rebuilding is
/// `stopStreaming()/startStreaming()`, which cancels the current connection, so
/// a live session must never be torn down to satisfy a rebuild (lesson 156 —
/// rebuilding a healthy listener on every foreground produced "connection
/// reset by peer").
public enum ForegroundRecoveryPolicy {

    /// The listener's liveness, reduced to only what the decision needs so the
    /// policy has no dependency on `Network` and can be tested without a socket.
    public enum ListenerLiveness: Equatable, Sendable {
        /// No listener object exists (never started, or `stopStreaming` cleared it).
        case absent
        /// `.ready` — bound and advertising.
        case ready
        /// `.failed` — the system tore it down (e.g. `DefunctConnection` on resume).
        case failed
        /// `.cancelled` — torn down deliberately.
        case cancelled
        /// `.setup` / `.waiting` / `@unknown` — not clearly dead; leave it alone.
        case other
    }

    /// Whether foreground return should `stopStreaming()` + `startStreaming()`
    /// to rebuild the capture listener.
    ///
    /// - a live link → `false`, always: rebuilding cancels the connection.
    /// - `.absent` / `.failed` / `.cancelled` → `true`: nothing is listening, so
    ///   the phone is unreachable until it is rebuilt.
    /// - `.ready` / `.other` → `false`: a healthy (or transiently waiting)
    ///   listener must be left alone, or a live connection dies with it.
    public static func shouldRebuildListener(linkAlive: Bool,
                                             listener: ListenerLiveness) -> Bool {
        if linkAlive { return false }
        switch listener {
        case .absent, .failed, .cancelled: return true
        case .ready, .other: return false
        }
    }
}
