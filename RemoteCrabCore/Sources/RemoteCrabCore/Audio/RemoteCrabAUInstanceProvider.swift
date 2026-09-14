import Foundation

/// Hook used by the Mac host (RemoteCrabReceiver) and the
/// `RemoteCrabAudioExtension` extension to share a single
/// `RemoteCrabAudioUnit` instance. The extension bundle calls
/// `RemoteCrabAUInstanceProvider.makeInstance()` from its factory to
/// vend the same AU instance the host is feeding with iPhone-mic
/// samples — so the host process and the AUv3 instance share state.
///
/// Threading: this is set once at app launch from the main thread,
/// then read by both the host and the extension. Read/write is
/// guarded by an `NSLock` for safety.
public enum RemoteCrabAUInstanceProvider {
    nonisolated(unsafe) public static var _factory: () -> AnyObject = {
        NSObject()
    }
    private static let lock = NSLock()

    /// The current factory that produces the shared AU instance.
    /// Set by the host at startup, read by the extension bundle.
    public static var makeInstance: AnyObject {
        get {
            lock.lock(); defer { lock.unlock() }
            return _factory()
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _factory = { newValue }
        }
    }
}