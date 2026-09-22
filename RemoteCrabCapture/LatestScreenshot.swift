import Foundation
import Photos
import RemoteCrabCore
import UniformTypeIdentifiers

/// Fetches the newest screenshot from the photo library for the
/// "Latest Screenshot" send shortcut.
///
/// Selection (newest item, screenshots only) is delegated to
/// `ScreenshotPicker`; this type owns only the Photos plumbing and the
/// read-authorization prompt.
enum LatestScreenshot {

    enum Failure: Error {
        /// Read access was denied / restricted.
        case notAuthorized
        /// Access is fine but the library (or the `.limited` selection)
        /// contains no screenshot.
        case none
        /// The screenshot exists but its pixels couldn't be loaded.
        case loadFailed
    }

    /// Request read access if needed, then return the newest screenshot
    /// written to a temporary file the caller can hand to `sendFile`.
    static func newestFileURL() async throws -> URL {
        guard await ensureAuthorized() else { throw Failure.notAuthorized }

        let options = PHFetchOptions()
        // Screenshots only — the library may hold many thousands of
        // assets, and `ScreenshotPicker` should judge the newest from a
        // small set.
        options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0",
                                        PHAssetMediaSubtype.photoScreenshot.rawValue)
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var candidates: [ScreenshotPicker.Candidate] = []
        candidates.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            candidates.append(ScreenshotPicker.Candidate(
                id: asset.localIdentifier,
                creationDate: asset.creationDate ?? .distantPast,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }

        guard let winner = ScreenshotPicker.latestScreenshot(from: candidates),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [winner.id], options: nil).firstObject
        else { throw Failure.none }

        guard let (data, ext) = await loadData(for: asset) else { throw Failure.loadFailed }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecrab-screenshot-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        return tmp
    }

    // MARK: - Photos plumbing

    private static func ensureAuthorized() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// Full-resolution image data plus its preferred file extension.
    private static func loadData(for asset: PHAsset) async -> (Data, String)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(Data, String)?, Never>) in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            let lock = NSLock()
            var resumed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                lock.lock()
                defer { lock.unlock() }
                // The handler can fire more than once (degraded then full)
                // — resume the continuation only once.
                guard !resumed else { return }
                resumed = true
                guard let data else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: (data, Self.extension(for: uti)))
            }
        }
    }

    private static func `extension`(for uti: String?) -> String {
        guard let uti, let type = UTType(uti), let ext = type.preferredFilenameExtension else {
            return "png"
        }
        return ext
    }
}
