import AppKit
import XCTest
@testable import MinusOne

final class PlayheadOverlayTests: XCTestCase {
    private func overlay(width: CGFloat = 680, height: CGFloat = 300, clipDuration: Double = 240) -> PlayheadOverlayView {
        let view = PlayheadOverlayView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.viewport = Viewport(clipDuration: clipDuration, widthPoints: width)
        return view
    }

    func testThePlayheadSitsWhereTheViewportSaysItDoes() {
        let view = overlay()
        view.playheadTime = 60
        XCTAssertEqual(view.playheadX(), view.viewport.x(forTime: 60))
    }

    func testThereIsNoPlayheadUntilOneIsSet() {
        XCTAssertNil(overlay().playheadX())
    }

    /// One loop for the clip, drawn as one band across the whole stack — spec §7's "so it cannot
    /// be mistaken for lane-local state".
    func testTheLoopBandSpansTheFullHeight() throws {
        let view = overlay(height: 300)
        view.loopRange = 30...90
        let rect = try XCTUnwrap(view.loopRect())
        XCTAssertEqual(rect.minX, view.viewport.x(forTime: 30), accuracy: 0.001)
        XCTAssertEqual(rect.maxX, view.viewport.x(forTime: 90), accuracy: 0.001)
        XCTAssertEqual(rect.height, 300, accuracy: 0.001)
    }

    func testTheLoopBandFollowsAZoom() throws {
        let view = overlay()
        view.loopRange = 30...90
        let before = try XCTUnwrap(view.loopRect())
        view.viewport = view.viewport.zoomed(by: 4, around: 340)
        let after = try XCTUnwrap(view.loopRect())
        XCTAssertGreaterThan(after.width, before.width)
    }

    /// Events must reach the lanes underneath: the overlay is paint, not a control.
    func testItIsInvisibleToTheMouse() {
        let view = overlay()
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 100)))
    }

    /// The 60 fps claim: a playhead tick may invalidate a thin strip, never the whole stack.
    func testAPlayheadMoveInvalidatesOnlyAThinStrip() {
        let view = overlay(width: 680, height: 300)
        let rect = view.invalidationRect(forTime: 60)
        XCTAssertLessThan(rect.width, 8)
        XCTAssertEqual(rect.height, 300, accuracy: 0.001)
        XCTAssertTrue(rect.contains(NSPoint(x: view.viewport.x(forTime: 60), y: 150)))
    }

    func testItPaintsThePlayheadAndTheLoopBand() throws {
        let view = overlay(width: 300, height: 100, clipDuration: 10)
        view.loopRange = 2...4
        view.playheadTime = 6

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        func columnHasInk(_ x: Int) -> Bool {
            (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.05 }
        }
        let loopX = Int(view.viewport.x(forTime: 3)) * rep.pixelsWide / Int(view.bounds.width)
        let playheadX = Int(view.viewport.x(forTime: 6)) * rep.pixelsWide / Int(view.bounds.width)
        XCTAssertTrue(columnHasInk(loopX), "the loop band did not paint")
        XCTAssertTrue(columnHasInk(playheadX), "the playhead did not paint")
        XCTAssertFalse(columnHasInk(rep.pixelsWide - 2), "the overlay painted where nothing should be")
    }

    /// The snap is the whole point: a 1pt fill at a fractional x smears across two device pixels.
    func testTheHoverCursorLandsOnAWholeDevicePixel() throws {
        let view = overlay(width: 680, clipDuration: 240)
        view.hoverTime = 1.0

        let raw = view.viewport.x(forTime: 1.0)
        let snapped = try XCTUnwrap(view.hoverX())
        XCTAssertNotEqual(snapped, raw, accuracy: 0.0001, "the hover x was not snapped at all")
        // No window in a test, so the fallback scale of 2 applies.
        XCTAssertEqual((snapped * 2).rounded(), snapped * 2, accuracy: 0.0001)
        XCTAssertEqual(snapped, raw, accuracy: 0.5, "the snap moved the cursor more than half a point")
    }

    func testThereIsNoHoverCursorUntilOneIsSet() {
        XCTAssertNil(overlay().hoverX())
    }

    /// Two 1pt lines a fraction apart read as one smudge, so the hover yields to the playhead.
    func testTheHoverCursorIsSuppressedUnderThePlayhead() {
        let view = overlay()
        view.playheadTime = 60
        view.hoverTime = 60
        XCTAssertNil(view.hoverX())

        view.hoverTime = 61
        XCTAssertNotNil(view.hoverX())
    }
}
