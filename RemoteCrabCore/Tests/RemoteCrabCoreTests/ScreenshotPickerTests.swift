import XCTest
@testable import RemoteCrabCore

final class ScreenshotPickerTests: XCTestCase {

    private func candidate(_ id: String, _ offset: TimeInterval, screenshot: Bool) -> ScreenshotPicker.Candidate {
        ScreenshotPicker.Candidate(id: id,
                                   creationDate: Date(timeIntervalSince1970: offset),
                                   isScreenshot: screenshot)
    }

    func testPicksNewestScreenshotAmongMixed() {
        let items = [
            candidate("old-shot", 100, screenshot: true),
            candidate("new-shot", 300, screenshot: true),
            candidate("mid-photo", 200, screenshot: false),
        ]
        XCTAssertEqual(ScreenshotPicker.latestScreenshot(from: items)?.id, "new-shot")
    }

    func testIgnoresNewerOrdinaryPhoto() {
        let items = [
            candidate("shot", 100, screenshot: true),
            candidate("newer-photo", 900, screenshot: false),
        ]
        XCTAssertEqual(ScreenshotPicker.latestScreenshot(from: items)?.id, "shot")
    }

    func testReturnsNilWhenNoScreenshots() {
        let items = [
            candidate("a", 100, screenshot: false),
            candidate("b", 200, screenshot: false),
        ]
        XCTAssertNil(ScreenshotPicker.latestScreenshot(from: items))
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(ScreenshotPicker.latestScreenshot(from: []))
    }
}
