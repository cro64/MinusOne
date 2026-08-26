import AppKit
import XCTest
@testable import MinusOne

/// Writes PNGs of the assembled timeline for human inspection. Not an assertion suite — the
/// assertions live in the per-view tests. This exists because "the pixel-coverage tests pass" and
/// "the deck looks right" are different claims.
final class DeckTimelineRenderTests: XCTestCase {
    func testRenderTheTimelineForInspection() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A mix at full scale and four stems at different levels, so mix-relative normalisation
        // has something to show: the lanes must not all be the same height.
        let levels: [(PeakTrack, Float)] = [
            (.mix, 0.95),
            (.stem(.vocals), 0.5),
            (.stem(.drums), 0.95),
            (.stem(.bass), 0.2),
            (.stem(.other), 0.08)
        ]
        for (track, level) in levels {
            let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(track.fileName), sampleRate: 44_100)
            // Ten seconds of an amplitude that swells and dips, so bars vary along the lane.
            var samples: [Float] = []
            for frame in 0..<(10 * 44_100) {
                let envelope = 0.4 + 0.6 * abs(sin(Double(frame) / 40_000))
                samples.append(level * Float(envelope) * sinf(Float(frame) * 0.05))
            }
            try writer.append(samples)
            try writer.finish()
        }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = DeckTimelineView()
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 860, height: DeckTimelineView.height(forLaneCount: 4))
            view.show(clipDuration: 10, peakStore: PeakStore(peaksFolder: folder))
            view.readyDuration = 10
            view.loopRange = 2...5
            view.setPlayheadTime(3.5)
            view.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = output.appendingPathComponent("deck-timeline-\(name).png")
            try png.write(to: url)
            print("RENDERED \(url.path)")
        }

        // Guard against the trap this harness fell into once already: an appearance that never
        // reaches the view produces two identical PNGs, and a reader comparing them would conclude
        // a colour is frozen when the renderer simply ignored the appearance.
        let lightData = try Data(contentsOf: output.appendingPathComponent("deck-timeline-light.png"))
        let darkData = try Data(contentsOf: output.appendingPathComponent("deck-timeline-dark.png"))
        XCTAssertNotEqual(
            lightData, darkData,
            "light and dark renders are byte-identical — the appearance did not reach the view, so "
            + "these images cannot be used to judge dark-mode correctness"
        )
    }
}
