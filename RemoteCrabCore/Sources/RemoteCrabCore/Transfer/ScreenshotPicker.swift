import Foundation

/// Picks which photo-library item is "the latest screenshot" to send to
/// the Mac.
///
/// Pure so the selection rule — the newest item flagged as a screenshot,
/// ignoring ordinary photos — is unit-testable without the Photos
/// framework (`PHAsset` is unavailable to the package tests).
public enum ScreenshotPicker {

    /// A photo-library item reduced to just the fields the rule needs.
    public struct Candidate: Equatable {
        public let id: String
        public let creationDate: Date
        public let isScreenshot: Bool

        public init(id: String, creationDate: Date, isScreenshot: Bool) {
            self.id = id
            self.creationDate = creationDate
            self.isScreenshot = isScreenshot
        }
    }

    /// The newest screenshot, or `nil` when the library has none.
    public static func latestScreenshot(from candidates: [Candidate]) -> Candidate? {
        candidates
            .filter(\.isScreenshot)
            .max { $0.creationDate < $1.creationDate }
    }
}
