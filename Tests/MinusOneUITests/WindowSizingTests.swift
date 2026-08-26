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

    /// And at the floor it still fits vertically — the constraint that decides whether 900×600 is
    /// a floor or a promise the layout cannot keep.
    ///
    /// This **measures** the real deck rather than asserting a chrome literal. The first version of
    /// this test summed `52 + 66 + 90 + 24` by hand, and spec §8 itself annotated the 52pt header
    /// strip as "estimated — measure before fixing the numbers below". A hand-summed budget passes
    /// happily while the real window clips, which defeats the only test that exists to catch that.
    /// Measured: the deck's content stack wants 448pt against the 498pt those literals implied, so
    /// the original arithmetic was conservative — but only by luck.
    ///
    /// The Live/Practice header strip is the one figure still estimated: measuring it would mean
    /// constructing a real `MainWindowController`, which builds an `NSWindow` and an `AudioEngine`.
    /// It is isolated below, and the remaining slack absorbs a large error in it.
    func testTheDeckFitsTheMinimumWindowHeight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = PracticeDeckViewController(
            libraryStore: ClipLibraryStore(rootURL: root),
            playbackEngine: PracticePlaybackEngine()
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        // The deck view's own `fittingSize.height` is 0 — its content stack is pinned
        // top/leading/trailing with no bottom edge, so the view has no vertical intrinsic size.
        // The stack itself is the thing with a height.
        var stacks: [NSStackView] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView, stack.orientation == .vertical { stacks.append(stack) }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        let deckContent = try XCTUnwrap(stacks.map(\.fittingSize.height).max())
        XCTAssertGreaterThan(
            deckContent, DeckTimelineView.height(forLaneCount: 4),
            "the measured stack does not even contain the timeline — the wrong stack was found"
        )

        let headerStrip: CGFloat = 52
        let needed = deckContent + WindowUI.Metrics.padding + headerStrip
        XCTAssertLessThanOrEqual(
            needed, WindowSizing.minimum.height,
            "the deck needs \(needed)pt but the floor is \(WindowSizing.minimum.height)pt"
        )
    }
}
