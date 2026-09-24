import XCTest
@testable import RemoteCrabCore

final class VoiceEngineSelectorTests: XCTestCase {

    private let zh = "zh-Hans"
    private let en = "en-US"

    func testAnalyzerChosenWhenOSAndHardwareAndLocaleInstalled() {
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: true,
                analyzerHardwareAvailable: true,
                installedLocales: [zh, en],
                desiredLocales: [zh, en]
            ),
            .analyzer
        )
    }

    func testLegacyWhenOSTooOld() {
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: false,
                analyzerHardwareAvailable: true,
                installedLocales: [zh],
                desiredLocales: [zh]
            ),
            .legacy
        )
    }

    func testLegacyWhenHardwareUnavailable() {
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: true,
                analyzerHardwareAvailable: false,
                installedLocales: [zh],
                desiredLocales: [zh]
            ),
            .legacy
        )
    }

    func testLegacyWhenNoDesiredLocaleInstalled() {
        // Never download: a supported locale that isn't installed yet
        // must NOT select the analyzer engine.
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: true,
                analyzerHardwareAvailable: true,
                installedLocales: [en],
                desiredLocales: [zh, en]
            ),
            .analyzer,
            "en-US is installed and desired, so analyzer is still usable"
        )
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: true,
                analyzerHardwareAvailable: true,
                installedLocales: [zh],
                desiredLocales: ["ja-JP"]
            ),
            .legacy
        )
    }

    func testLocaleNormalization() {
        // zh_Hans installed, zh-Hans desired → match anyway.
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: true,
                analyzerHardwareAvailable: true,
                installedLocales: ["zh_Hans"],
                desiredLocales: ["zh-Hans"]
            ),
            .analyzer
        )
        // Case-insensitive.
        XCTAssertEqual(
            VoiceEngineSelector.choose(
                osSupportsAnalyzer: true,
                analyzerHardwareAvailable: true,
                installedLocales: ["EN-us"],
                desiredLocales: ["en-US"]
            ),
            .analyzer
        )
    }
}
