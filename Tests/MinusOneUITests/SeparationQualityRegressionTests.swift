import Accelerate
import AVFoundation
import XCTest
@testable import MinusOne

/// Drives `OfflineSeparationEngine` directly against synthetic, perfectly-isolated stems and
/// scores the result with SI-SDR via `SeparationQualityHarness` — no Python invocation, no app
/// launch: `swift test --filter SeparationQualityRegressionTests` is the whole loop.
///
/// This is a fast smoke test against synthetic tones/noise, not a substitute for scoring against
/// real music — see `SeparationQualityBenchmarkTests` (real MUSDB18 tracks via
/// `Scripts/fetch_musdb18.py`) for the deep pass. What this guards against is a pipeline change
/// (windowing, hop, resampling, normalization) silently breaking reconstruction, which synthetic
/// signals catch just as well as real ones and without a multi-GB dataset dependency.
final class SeparationQualityRegressionTests: XCTestCase {
    private var root: URL!
    private var libraryStore: ClipLibraryStore!

    private let sampleRate = 44_100.0
    private let clipSeconds = 18.0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparationQuality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        libraryStore = ClipLibraryStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Needs the real Demucs CoreML model on disk (`Scripts/download-model.sh`, or the welcome
    /// screen's download) — skips rather than fails where it isn't, so this doesn't block CI on a
    /// machine that's never downloaded it, but becomes a real regression gate the moment it has.
    func testOfflineSeparationReconstructsKnownStemsAboveFloor() throws {
        try XCTSkipUnless(
            SeparationModelFactory.isAvailable(.balanced),
            "Separation model not downloaded — run Scripts/download-model.sh first."
        )

        let references = Self.syntheticStems(seconds: clipSeconds, sampleRate: sampleRate)
        let mixURL = root.appendingPathComponent("mix.caf")
        try Self.writeMix(references, to: mixURL, sampleRate: sampleRate)

        let clip = PracticeClip(
            title: "Synthetic quality fixture",
            durationSeconds: clipSeconds,
            sourceHash: "synthetic-fixture",
            sourceFileName: "mix.caf",
            waveformPeaks: []
        )
        libraryStore.add(clip)

        let engine = OfflineSeparationEngine(libraryStore: libraryStore)
        // CPU-bound CoreML inference over ~18s of audio across several windows — generous but
        // bounded, so a genuine hang (not just "slow machine") still fails instead of blocking CI.
        let updated = try SeparationQualityHarness.runSeparation(
            engine: engine, clip: clip, sourceURL: mixURL, timeout: 300
        )

        var scores: [SeparationStem: Double] = [:]
        for stem in SeparationStem.allCases {
            let fileName = try XCTUnwrap(updated.stemFileNames[stem.rawValue], "\(stem.rawValue) never wrote a file")
            let url = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)
            let estimate = try SeparationQualityHarness.readStereo(url)
            let reference = references[stem]!
            scores[stem] = SeparationQualityHarness.siSDR(reference: reference, estimate: estimate)
        }

        let report = scores.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))dB" }.joined(separator: ", ")
        print("[SeparationQualityRegressionTests] SI-SDR: \(report)")

        // Deliberately lenient: this floor exists to catch a pipeline bug that produces silence,
        // NaNs, or a fully-scrambled stem (score would be deeply negative or crash the log10),
        // not to certify separation quality — tighten it only after establishing a real baseline
        // number on real hardware, since this sandbox can't run CoreML to calibrate one.
        for (stem, score) in scores {
            XCTAssertFalse(score.isNaN, "\(stem.rawValue) SI-SDR is NaN — likely silent or empty output")
            XCTAssertGreaterThan(score, -10, "\(stem.rawValue) SI-SDR regressed to near-noise-floor")
        }
    }

    // MARK: - Synthetic fixtures

    /// Four spectrally-distinct synthetic "stems" standing in for vocals/drums/bass/other, so the
    /// model has something to actually tell apart — matching frequency ranges roughly where each
    /// real stem tends to live (vocals mid, bass low, drums broadband/percussive, other high).
    private static func syntheticStems(seconds: Double, sampleRate: Double) -> [SeparationStem: (left: [Float], right: [Float])] {
        let count = Int(seconds * sampleRate)
        var vocals = [Float](repeating: 0, count: count)
        var bass = [Float](repeating: 0, count: count)
        var other = [Float](repeating: 0, count: count)
        var drums = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let t = Double(i) / sampleRate
            vocals[i] = Float(0.25 * sin(2 * .pi * 440 * t))
            bass[i] = Float(0.3 * sin(2 * .pi * 80 * t))
            other[i] = Float(0.2 * sin(2 * .pi * 1_200 * t))
        }

        var rng = SystemRandomNumberGenerator()
        let beatSamples = Int(0.5 * sampleRate)
        var position = 0
        var beatIndex = 0
        while position < count {
            let amplitude: Float = beatIndex % 4 == 0 ? 0.9 : 0.35
            for offset in 0..<220 where position + offset < count {
                let decay = 1 - Float(offset) / 220
                drums[position + offset] = amplitude * decay * Float.random(in: -1...1, using: &rng)
            }
            position += beatSamples
            beatIndex += 1
        }

        func stereo(_ mono: [Float]) -> (left: [Float], right: [Float]) { (mono, mono) }
        return [
            .vocals: stereo(vocals),
            .drums: stereo(drums),
            .bass: stereo(bass),
            .other: stereo(other)
        ]
    }

    private static func writeMix(
        _ stems: [SeparationStem: (left: [Float], right: [Float])],
        to url: URL,
        sampleRate: Double
    ) throws {
        let count = stems.values.first!.left.count
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for (_, channels) in stems {
            vDSP_vadd(left, 1, channels.left, 1, &left, 1, vDSP_Length(count))
            vDSP_vadd(right, 1, channels.right, 1, &right, 1, vDSP_Length(count))
        }

        var peak: Float = 0
        vDSP_maxmgv(left, 1, &peak, vDSP_Length(count))
        var peakRight: Float = 0
        vDSP_maxmgv(right, 1, &peakRight, vDSP_Length(count))
        peak = max(peak, peakRight)
        if peak > 1 {
            var scale = 1 / peak
            vDSP_vsmul(left, 1, &scale, &left, 1, vDSP_Length(count))
            vDSP_vsmul(right, 1, &scale, &right, 1, vDSP_Length(count))
        }

        try SeparationQualityHarness.writeStereo(left: left, right: right, to: url, sampleRate: sampleRate)
    }
}
