// Tests/MinusOneUITests/HeroWaveformViewTests.swift
import AppKit
import XCTest
@testable import MinusOne

final class HeroWaveformViewTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeroWaveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTrack(_ track: PeakTrack, seconds: Double, magnitude: Float) throws {
        let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(track.fileName), sampleRate: 44_100)
        try writer.append([Float](repeating: magnitude, count: Int(seconds * 44_100)))
        try writer.finish()
    }

    private func hero(width: CGFloat = 900, clipDuration: Double = 60) -> HeroWaveformView {
        let view = HeroWaveformView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        view.show(clipDuration: clipDuration, peakStore: PeakStore(peaksFolder: folder))
        return view
    }

    func testItDrawsOneBarAcrossTheWholeTrackNotAZoomedWindow() throws {
        try writeTrack(.mix, seconds: 60, magnitude: 0.9)
        let view = hero(width: 900, clipDuration: 60)
        let bars = view.renderedBars()
        XCTAssertEqual(bars.count, TimelineMetrics.barCount(forWidth: 900))
        XCTAssertEqual(bars[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(bars[bars.count - 1].time, 60, accuracy: 1.0)
    }

    func testItReusesItsBitmapUntilSomethingChanges() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        let view = hero(width: 300, clipDuration: 10)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 1)
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 1, "an unchanged hero re-rendered its bars")

        view.frame = NSRect(x: 0, y: 0, width: 400, height: 64)
        let resized = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: resized)
        XCTAssertEqual(view.renderCount, 2, "a resize did not invalidate the cache")
    }

    func testTheUnseparatedPortionPaintsTheFlatTailColor() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        for stem in SeparationStem.allCases { try writeTrack(.stem(stem), seconds: 4, magnitude: 0.9) }
        let view = hero(width: 300, clipDuration: 10)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let tailX = Int(view.x(forTime: 9.5))
        let expected = try XCTUnwrap(HeroWaveformBlend.tailColor.usingColorSpace(.sRGB))
        var sawTail = false
        for y in 0..<rep.pixelsHigh {
            guard let pixel = rep.colorAt(x: tailX, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.05 else { continue }
            if abs(pixel.alphaComponent - expected.alphaComponent) < 0.1 { sawTail = true }
        }
        XCTAssertTrue(sawTail, "the unseparated portion did not paint the flat tail color")
    }

    func testItBlendsTowardADominantStemsColorWhereThatStemIsLoud() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        try writeTrack(.stem(.vocals), seconds: 10, magnitude: 0.9)
        // See Task 1's identical note: 0.001 sits at the -60dB floor where `PeakScaling.height`
        // clamps to exactly 0, so these three stems contribute no weight at all — 0.02 (-34dB) still
        // carries real weight under the dB-floor mapping and only produces a ~43% vocal blend.
        try writeTrack(.stem(.drums), seconds: 10, magnitude: 0.001)
        try writeTrack(.stem(.bass), seconds: 10, magnitude: 0.001)
        try writeTrack(.stem(.other), seconds: 10, magnitude: 0.001)
        let view = hero(width: 300, clipDuration: 10)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let x = Int(view.x(forTime: 5))
        let expected = try XCTUnwrap(SeparationStem.vocals.identityColor.usingColorSpace(.sRGB))
        var matched = 0
        var inked = 0
        for y in 0..<rep.pixelsHigh {
            guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.05 else { continue }
            inked += 1
            if abs(pixel.redComponent - expected.redComponent) < 0.12,
               abs(pixel.greenComponent - expected.greenComponent) < 0.12,
               abs(pixel.blueComponent - expected.blueComponent) < 0.12 {
                matched += 1
            }
        }
        XCTAssertGreaterThan(inked, 0, "the hero drew nothing at all")
        XCTAssertGreaterThan(Double(matched) / Double(inked), 0.5, "the hero is not blending toward vocals where vocals dominate")
    }

    func testAZeroWidthHeroRendersNothingRatherThanCrashing() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        let view = hero(width: 0, clipDuration: 10)
        XCTAssertTrue(view.renderedBars().isEmpty)
    }
}
