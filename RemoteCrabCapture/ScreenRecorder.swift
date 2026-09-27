// Debug-only developer tooling. Not present in release builds: the recorder
// exists to produce demo and marketing footage on a physical device, and
// nothing a shipping user would want. Keeping it out of release also keeps
// ReplayKit unlinked and the Settings sheet free of a capability that an App
// Review reader would reasonably read as screen capture.
#if DEBUG
import Foundation
import OSLog
import ReplayKit
import SwiftUI
import UIKit

/// Wraps `RPScreenRecorder` so the user can record the app's own screen from
/// inside the app.
///
/// Why this exists: macOS has no CLI path for recording a physical iPhone's
/// screen (`simctl io recordVideo` is Simulator-only, and QuickTime's device
/// route is GUI + a TCC prompt that hangs scripts). In-app ReplayKit sidesteps
/// all of that — the user taps record on the phone, the clip lands in Files /
/// Photos, and `devicectl device copy from` pulls it off the device. That
/// makes every future demo or marketing clip reproducible instead of a
/// hand-held re-record.
///
/// Audio is off by default: the app already owns the microphone for streaming
/// and hold-to-talk, and letting ReplayKit take it too risks the session
/// conflicts documented in the microphone lessons. Turn it on only for a
/// take that needs narration.
@MainActor
@Observable
final class ScreenRecorder {
    private static let log = Logger(subsystem: "com.remotecrab", category: "recorder")

    /// Wraps the ReplayKit preview so SwiftUI can present it via `.sheet(item:)`.
    struct Preview: Identifiable {
        let id = UUID()
        let controller: RPPreviewViewController
    }

    private(set) var isAvailable = RPScreenRecorder.shared().isAvailable
    private(set) var isRecording = false
    private(set) var lastError: String?
    /// Sheet payload; non-nil right after a successful stop.
    var preview: Preview?

    /// Include microphone audio in the recording. Off by default — see above.
    var includeMicrophone = false

    /// Re-reads availability. Call when the settings sheet appears, because
    /// ReplayKit availability changes with Screen Recording restrictions.
    func refresh() {
        let recorder = RPScreenRecorder.shared()
        isAvailable = recorder.isAvailable
        isRecording = recorder.isRecording
    }

    func start() {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            fail("ReplayKit unavailable")
            return
        }
        guard !recorder.isRecording else { return }

        recorder.isMicrophoneEnabled = includeMicrophone
        lastError = nil
        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.fail("\(error.localizedDescription)")
                    return
                }
                self.isRecording = true
                Self.log.info("screen recording started (mic: \(self.includeMicrophone))")
            }
        }
    }

    func stop() {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isRecording else { return }

        recorder.stopRecording { [weak self] controller, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                if let error {
                    self.fail("\(error.localizedDescription)")
                    return
                }
                guard let controller else {
                    self.fail("no preview controller returned")
                    return
                }
                self.preview = Preview(controller: controller)
                Self.log.info("screen recording stopped; preview ready")
            }
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func dismissPreview() {
        preview = nil
    }

    private func fail(_ message: String) {
        lastError = message
        isRecording = false
        Self.log.error("screen recording failed: \(message, privacy: .public)")
    }
}

/// ReplayKit hands back a `UIViewController` (its own save/share sheet),
/// so it needs a representable to be presented from SwiftUI.
struct RecorderPreviewView: UIViewControllerRepresentable {
    let controller: RPPreviewViewController

    func makeUIViewController(context: Context) -> RPPreviewViewController { controller }

    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) {}
}
#endif
