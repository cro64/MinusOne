// Tests/MinusOneUITests/HeroWaveformOverlayTests.swift
import AppKit
import XCTest
@testable import MinusOne

final class HeroWaveformOverlayTests: XCTestCase {
    private func hero(width: CGFloat = 900, clipDuration: Double = 60) -> HeroWaveformView {
        let view = HeroWaveformView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        view.show(clipDuration: clipDuration, peakStore: PeakStore(peaksFolder: FileManager.default.temporaryDirectory))
        return view
    }

    func testVisibleRangeRectMapsAcrossTheWholeTrack() throws {
        let view = hero(width: 900, clipDuration: 60)
        view.visibleRange = 10...20
        let rect = try XCTUnwrap(view.visibleRangeRect())
        XCTAssertEqual(rect.minX, view.x(forTime: 10), accuracy: 0.01)
        XCTAssertEqual(rect.width, view.x(forTime: 20) - view.x(forTime: 10), accuracy: 0.01)
    }

    func testNoVisibleRangeRectWhenUnset() {
        XCTAssertNil(hero().visibleRangeRect())
    }

    func testPlayheadXMapsAcrossTheWholeTrack() throws {
        let view = hero(width: 900, clipDuration: 60)
        view.playheadTime = 30
        XCTAssertEqual(try XCTUnwrap(view.playheadX()), view.x(forTime: 30), accuracy: 0.01)
    }

    /// Same suppression rule `PlayheadOverlayView.hoverX()` documents: a hover cursor exactly on the
    /// playhead reads as one smudge, not two overlapping lines.
    func testHoverIsSuppressedUnderThePlayhead() {
        let view = hero(width: 900, clipDuration: 60)
        view.playheadTime = 30
        view.hoverTime = 30
        XCTAssertNil(view.hoverX())
        view.hoverTime = 31
        XCTAssertNotNil(view.hoverX())
    }
}
