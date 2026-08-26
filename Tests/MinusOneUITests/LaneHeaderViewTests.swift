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

    func testSoloReportsAndReflectsState() {
        let header = LaneHeaderView(stem: .vocals)
        var count = 0
        header.onSoloToggled = { count += 1 }
        header.toggleSoloForTesting()
        XCTAssertEqual(count, 1)

        // The engine owns solo state (only one stem can hold it), so the header is told, not asked.
        header.setSoloed(true)
        XCTAssertTrue(header.isSoloedForTesting)
        header.setSoloed(false)
        XCTAssertFalse(header.isSoloedForTesting)
    }

    /// Same rule as today's mixer row: no exporting a stem separation hasn't finished writing.
    func testExportIsDisabledUntilEnabled() {
        let header = LaneHeaderView(stem: .other)
        XCTAssertFalse(header.isExportEnabledForTesting)
        header.setExportEnabled(true)
        XCTAssertTrue(header.isExportEnabledForTesting)
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
