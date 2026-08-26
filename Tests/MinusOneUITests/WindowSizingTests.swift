import AppKit
import XCTest
@testable import MinusOne

final class WindowSizingTests: XCTestCase {
    func testTheDefaultAndTheFloorAreNoLongerTheSameValue() {
        XCTAssertNotEqual(WindowSizing.defaultContent, WindowSizing.minimum)
        XCTAssertGreaterThan(WindowSizing.defaultContent.width, WindowSizing.minimum.width)
        XCTAssertGreaterThan(WindowSizing.defaultContent.height, WindowSizing.minimum.height)
    }

    func testTheDefaultMatchesTheSpec() {
        XCTAssertEqual(WindowSizing.defaultContent, NSSize(width: 1120, height: 760))
        XCTAssertEqual(WindowSizing.minimum, NSSize(width: 900, height: 600))
    }

    /// Spec §8's arithmetic, as an assertion rather than a table: at the default width and the
    /// widest sidebar the deck still has a usable canvas.
    func testTheLaneCanvasIsWideEnoughAtTheDefaultSize() {
        let widestSidebar: CGFloat = 360
        let deckPadding = WindowUI.Metrics.padding * 2
        let canvas = WindowSizing.defaultContent.width - widestSidebar - deckPadding - TimelineMetrics.headerWidth
        XCTAssertGreaterThan(TimelineMetrics.barCount(forWidth: canvas), 150, "fewer than 150 bars fit the lane")
    }

    /// And at the floor it still fits vertically, which is the constraint that decides whether
    /// 900×600 is a floor or a promise the layout cannot keep.
    func testTheDeckFitsTheMinimumWindowHeight() {
        // Header strip + deck padding/title/status + transport and tempo rows + bottom padding,
        // measured from the deck's own constants rather than guessed.
        let chrome: CGFloat = 52 + 66 + 90 + 24
        XCTAssertLessThanOrEqual(
            chrome + DeckTimelineView.height(forLaneCount: 4),
            WindowSizing.minimum.height,
            "four lanes plus chrome do not fit the 600pt floor"
        )
    }
}
