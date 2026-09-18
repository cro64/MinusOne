import XCTest
@testable import MinusOne

final class StatusHeaderViewCopyTests: XCTestCase {
    func testErrorCopyMentionsAnErrorNotJustStopped() {
        let copy = StatusHeaderView.copy(for: .error("boom"), isFilterActive: false)
        XCTAssertEqual(copy.title, "Error")
        XCTAssertTrue(copy.tooltipDetail.lowercased().contains("error"))
        XCTAssertEqual(copy.errorDetail, "boom")
    }

    func testActiveIsOnWhenFilterIsActive() {
        let copy = StatusHeaderView.copy(for: .active, isFilterActive: true)
        XCTAssertEqual(copy.title, "On")
        XCTAssertTrue(copy.tooltipDetail.lowercased().contains("reducing"))
    }

    func testActiveIsOffWhenFilterIsInactive() {
        let copy = StatusHeaderView.copy(for: .active, isFilterActive: false)
        XCTAssertEqual(copy.title, "Off")
        XCTAssertFalse(copy.tooltipDetail.lowercased().contains("reducing vocals"))
    }

    func testPassthroughAndIdleBothReadAsOff() {
        let passthrough = StatusHeaderView.copy(for: .passthrough, isFilterActive: true)
        let idle = StatusHeaderView.copy(for: .idle, isFilterActive: true)
        XCTAssertEqual(passthrough.title, "Off")
        XCTAssertEqual(idle.title, "Off")
        XCTAssertEqual(passthrough.tooltipDetail, idle.tooltipDetail)
    }

    func testWarmingUpCopyIncludesCountdownWhenProvided() {
        let copy = StatusHeaderView.copy(for: .warmingUp, isFilterActive: false, warmupRemainingSeconds: 8.4)
        XCTAssertTrue(copy.tooltipDetail.contains("9") || copy.tooltipDetail.contains("8"))
    }

    /// The countdown has to live in the *title* — the prominent, glanceable element — not just the
    /// tooltip/meter-caption text, or a user staring at the hero card sees no indication of how
    /// much longer they're waiting.
    func testWarmingUpTitleIncludesTheCountdown() {
        let copy = StatusHeaderView.copy(for: .warmingUp, isFilterActive: false, warmupRemainingSeconds: 8.4)
        XCTAssertTrue(copy.title.contains("9") || copy.title.contains("8"), "title was \"\(copy.title)\"")
    }

    func testWarmingUpCopyOmitsCountdownWhenNil() {
        let copy = StatusHeaderView.copy(for: .warmingUp, isFilterActive: false, warmupRemainingSeconds: nil)
        XCTAssertFalse(copy.tooltipDetail.contains(where: \.isNumber))
        XCTAssertEqual(copy.title, "Warming up")
    }

    func testPermissionCopyDistinguishesMicrophoneAndSystemAudio() {
        let mic = StatusHeaderView.copy(for: .permissionRequired(.microphone), isFilterActive: false)
        let systemAudio = StatusHeaderView.copy(for: .permissionRequired(.systemAudioRecording), isFilterActive: false)
        XCTAssertNotEqual(mic.tooltipDetail, systemAudio.tooltipDetail)
        XCTAssertTrue(mic.tooltipDetail.lowercased().contains("microphone"))
        XCTAssertTrue(systemAudio.tooltipDetail.lowercased().contains("system audio"))
    }
}
