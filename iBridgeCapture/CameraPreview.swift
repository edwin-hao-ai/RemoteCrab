import AVFoundation
import SwiftUI
import UIKit

/// A SwiftUI wrapper around a SHARED `PreviewView`. The app keeps exactly
/// one `AVCaptureVideoPreviewLayer` for the whole session: measured on
/// iPhone 14 / iOS 26, attaching a second preview layer blocks the main
/// thread for ~9 s at cold start (the camera daemon serializes preview
/// client registration). The full-screen camera surface and the PiP
/// therefore reparent the same view instead of each owning a layer.
struct CameraPreview: UIViewRepresentable {
    let view: PreviewView

    func makeUIView(context: Context) -> PreviewView { view }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    /// NSObjectProtocol isn't Sendable, which blocks removing the
    /// observer from a nonisolated deinit — box it to hop the check.
    private struct UnsafeSendableBox<T>: @unchecked Sendable {
        let value: T
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        let label: String
        private var pending: AVCaptureSession?
        private var startObserver: UnsafeSendableBox<NSObjectProtocol>?

        init(label: String) {
            self.label = label
            super.init(frame: .zero)
            previewLayer.videoGravity = .resizeAspectFill
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        deinit {
            if let startObserver {
                NotificationCenter.default.removeObserver(startObserver.value)
            }
        }

        /// Attaching a preview layer to a session that is still being
        /// configured / started is doubly bad: the setter serializes
        /// against `startRunning()` on the capture queue (blocking the
        /// main thread for the whole session start), and on iOS 26 a
        /// layer attached before the session runs can wedge into
        /// rendering black forever — observed on device: black preview
        /// until the view was destroyed and recreated. Defer the attach
        /// until the session reports DidStartRunning.
        func attach(to session: AVCaptureSession) {
            if session.isRunning {
                pending = nil
                if previewLayer.session !== session {
                    Forensic.log("[preview] \(label) attach begin")
                    previewLayer.session = session
                    Forensic.log("[preview] \(label) attach end")
                }
                return
            }
            guard pending !== session else { return }
            pending = session
            Forensic.log("[preview] \(label) attach deferred — session not running yet")
            if startObserver == nil {
                let token = NotificationCenter.default.addObserver(
                    forName: .AVCaptureSessionDidStartRunning,
                    object: session,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, let pending = self.pending else { return }
                    self.pending = nil
                    Forensic.log("[preview] \(self.label) attach begin (after DidStartRunning)")
                    self.previewLayer.session = pending
                    Forensic.log("[preview] \(self.label) attach end (after DidStartRunning)")
                }
                startObserver = UnsafeSendableBox(value: token)
            }
        }
    }
}
