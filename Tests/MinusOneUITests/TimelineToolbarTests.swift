import AppKit
import XCTest
@testable import MinusOne

final class TimelineToolbarTests: XCTestCase {
    func testItFitsTheToolbarRow() {
        let toolbar = TimelineToolbarView()
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(toolbar.fittingSize.height, TimelineMetrics.toolbarHeight)
    }

    /// Spec §6: below the confidence threshold "the BPM field is left empty, inviting a tap".
    /// An empty field is the invitation; a fabricated 120 would be a lie.
    func testWithNoGridTheFieldIsEmpty() {
        let toolbar = TimelineToolbarView()
        toolbar.setBPM(nil)
        XCTAssertTrue(toolbar.displayedBPMForTesting.isEmpty, "showed \(toolbar.displayedBPMForTesting) with no grid")
    }

    func testItShowsADetectedTempo() {
        let toolbar = TimelineToolbarView()
        toolbar.setBPM(128.4)
        XCTAssertEqual(toolbar.displayedBPMForTesting, "128.4")
    }

    func testEditingTheFieldReportsTheNewTempo() {
        let toolbar = TimelineToolbarView()
        var reported: [Double] = []
        toolbar.onBPMEdited = { reported.append($0) }

        toolbar.commitBPMForTesting("96")
        XCTAssertEqual(reported, [96])
    }

    /// A typo must not become a grid. Out-of-range and nonsense both leave the tempo alone.
    func testNonsenseInTheFieldIsRejected() {
        let toolbar = TimelineToolbarView()
        var reported: [Double] = []
        toolbar.onBPMEdited = { reported.append($0) }

        toolbar.commitBPMForTesting("banana")
        toolbar.commitBPMForTesting("")
        toolbar.commitBPMForTesting("0")
        toolbar.commitBPMForTesting("9000")
        XCTAssertTrue(reported.isEmpty, "accepted \(reported)")
    }

    /// Rejecting an edit must restore what was there, not leave the user's typo on screen.
    func testARejectedEditRestoresTheDisplayedTempo() {
        let toolbar = TimelineToolbarView()
        toolbar.setBPM(120)
        toolbar.commitBPMForTesting("banana")
        XCTAssertEqual(toolbar.displayedBPMForTesting, "120")
    }

    func testTappingReportsEachTap() {
        let toolbar = TimelineToolbarView()
        var taps = 0
        toolbar.onTapped = { taps += 1 }
        toolbar.tapForTesting()
        toolbar.tapForTesting()
        XCTAssertEqual(taps, 2)
    }
}
