import Foundation

/// The single source of truth for which RemoteCrab capabilities are live.
///
/// Owned by `CaptureEngine` on iOS; every toggle — local UI or a
/// remote `FeatureControl` frame from the Mac — flows through
/// `set(feature:enabled:)`, which fires `onChange` exactly once per
/// actual change so the engine can broadcast a `featureState` frame
/// and sync side effects (e.g. starting/stopping the mic encoder).
@Observable
@MainActor
public final class FeatureStore {

    /// Camera starts OFF: streaming video on launch is the surprising
    /// default. Many users only want the mic, the trackpad, or voice
    /// typing, so every stream is opt-in from the feature dock (the
    /// local preview keeps running either way — nothing is SENT until
    /// the user turns the camera on).
    public private(set) var cameraOn = false
    public private(set) var micOn = false
    public private(set) var voiceOn = false
    public private(set) var trackpadOn = true
    public private(set) var keyboardOn = true

    /// Which physical camera is streaming (front/back).
    public private(set) var cameraPosition: IBCameraPosition = .back

    /// Which interaction surface currently occupies the screen.
    /// Not broadcast-affecting on its own, but included in snapshots.
    public var activeSurface: Surface = .cameraPreview {
        didSet {
            if activeSurface != oldValue { notify() }
        }
    }

    /// Called once per actual state change with a fresh snapshot.
    public var onChange: (@MainActor (FeatureStateSnapshot) -> Void)?

    public init() {}

    public func set(feature: IBFeature, enabled: Bool) {
        let changed: Bool
        switch feature {
        case .camera:
            changed = cameraOn != enabled; cameraOn = enabled
        case .microphone:
            changed = micOn != enabled; micOn = enabled
        case .voice:
            changed = voiceOn != enabled; voiceOn = enabled
        case .trackpad:
            changed = trackpadOn != enabled; trackpadOn = enabled
        case .keyboard:
            changed = keyboardOn != enabled; keyboardOn = enabled
        }
        if changed { notify() }
    }

    /// Apply a remote toggle from the Mac. Identical to a local toggle.
    public func apply(_ control: FeatureControl) {
        set(feature: control.feature, enabled: control.enabled)
    }

    /// Record that the streaming camera changed position.
    public func setCameraPosition(_ position: IBCameraPosition) {
        guard cameraPosition != position else { return }
        cameraPosition = position
        notify()
    }

    public func snapshot() -> FeatureStateSnapshot {
        FeatureStateSnapshot(
            cameraOn: cameraOn,
            micOn: micOn,
            voiceOn: voiceOn,
            trackpadOn: trackpadOn,
            keyboardOn: keyboardOn,
            activeSurface: activeSurface,
            cameraPosition: cameraPosition,
            timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)
        )
    }

    private func notify() {
        onChange?(snapshot())
    }
}
