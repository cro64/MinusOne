import AppKit
import XCTest
@testable import MinusOne

final class LaneHeaderViewTests: XCTestCase {
    /// The header has to live inside the width spec §8's window arithmetic assumes and the lane
    /// height the stack gives it. If this fails the controls are overflowing, not merely tight.
    func testItFitsTheLaneHeaderBox() {
        for stem in SeparationStem.allCases {
            let header = LaneHeaderView(stem: stem)
            header.layoutSubtreeIfNeeded()
            let fitting = header.fittingSize
            XCTAssertLessThanOrEqual(fitting.width, TimelineMetrics.headerWidth, "\(stem) header is \(fitting.width)pt wide")
            XCTAssertLessThanOrEqual(fitting.height, TimelineMetrics.laneHeight, "\(stem) header is \(fitting.height)pt tall")
        }
    }

    func testTheFaderReportsItsValue() {
        let header = LaneHeaderView(stem: .bass)
        var reported: [Float] = []
        header.onVolumeChanged = { reported.append($0) }
        header.setVolumeForTesting(0.25)
        XCTAssertEqual(reported, [0.25])
    }

    func testMuteReportsBothDirections() {
        let header = LaneHeaderView(stem: .drums)
        var reported: [Bool] = []
        header.onMuteToggled = { reported.append($0) }
        header.toggleMuteForTesting()
        header.toggleMuteForTesting()
        XCTAssertEqual(reported, [true, false])
    }

    /// There is no separate solo state to reflect — isolating is cross-lane (it mutes every other
    /// stem too), so the header only requests it and waits to be told the resulting mute state,
    /// the same "told, not asked" contract `setMuted(_:)` already has.
    func testIsolateRequestsWithoutPredictingLocalMuteState() {
        let header = LaneHeaderView(stem: .vocals)
        var count = 0
        header.onIsolateRequested = { count += 1 }
        header.isolateForTesting()
        XCTAssertEqual(count, 1)
        XCTAssertFalse(header.isMutedForTesting, "isolate must not locally flip mute before being told")

        header.setMuted(true)
        XCTAssertTrue(header.isMutedForTesting)
    }

    /// Same rule as today's mixer row: no exporting a stem separation hasn't finished writing.
    func testExportIsDisabledUntilEnabled() {
        let header = LaneHeaderView(stem: .other)
        XCTAssertFalse(header.isExportEnabledForTesting)
        header.setExportEnabled(true)
        XCTAssertTrue(header.isExportEnabledForTesting)
    }

    /// The switch reads as a checkbox that is checked while the stem plays, so its label is the stem's
    /// name. "Mute Drums, checked" would tell a VoiceOver user the opposite of what is happening.
    func testTheSwitchIsLabelledWithTheStemNameAlone() throws {
        func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        for stem in SeparationStem.allCases {
            let header = LaneHeaderView(stem: stem)
            let toggle = try XCTUnwrap(descendants(of: header).compactMap { $0 as? MuteToggleView }.first, "\(stem) has no switch")
            XCTAssertEqual(toggle.accessibilityLabel(), stem.displayName, "\(stem)")
        }
    }

    /// The 13pt-label contrast rule DesignColors records: the fill hue is for the fader, the text
    /// variant is for the name.
    func testTheNameUsesTheTextVariantOfTheIdentityColor() {
        for stem in SeparationStem.allCases {
            let header = LaneHeaderView(stem: stem)
            XCTAssertEqual(header.nameColorForTesting, stem.identityTextColor, "\(stem)")
        }
    }
}
