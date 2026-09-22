import AVFoundation
import XCTest
@testable import MinusOne

/// Benchmarks `OfflineSeparationEngine` against real MUSDB18 tracks with authentic ground-truth
/// stems (not synthetic tones) — the deep, occasional companion to
/// `SeparationQualityRegressionTests`' fast synthetic smoke test.
///
/// Needs both the separation model and a local MUSDB18 dump, neither of which belong in git, so
/// this skips cleanly when either is missing rather than failing CI:
///
///     Scripts/download-model.sh
///     python3 Scripts/fetch_musdb18.py --limit 5
///     swift test --filter SeparationQualityBenchmarkTests
///
/// One command end to end — no app launch, no manual import/export, no separate Python
/// invocation to score the result (scoring is `SeparationQualityHarness.siSDR`, the same formula
/// `Scripts/evaluate_separation.py` uses, so a from-Python cross-check reports the same numbers).
final class SeparationQualityBenchmarkTests: XCTestCase {
    private var workRoot: URL!
    private var libraryStore: ClipLibraryStore!

    override func setUpWithError() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparationBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        libraryStore = ClipLibraryStore(rootURL: workRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workRoot)
    }

    /// `#filePath` at compile time resolves to this file's real location in the checkout under
    /// plain `swift test` (no DerivedData indirection), so three `deletingLastPathComponent()`
    /// calls reach the repo root — same technique `InfoPlistTests` already uses to find
    /// `Resources/Info.plist`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinusOneUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private static var datasetRoot: URL {
        repoRoot.appendingPathComponent(".musdb18/tracks", isDirectory: true)
    }

    /// Caps a default run to a handful of tracks so this stays a "run it locally in a few
    /// minutes" check rather than accidentally becoming an hours-long full-dataset pass. Raise it
    /// (after `fetch_musdb18.py --limit N` with a matching or larger N) when you actually want a
    /// wider sample.
    private static var trackLimit: Int {
        if let raw = ProcessInfo.processInfo.environment["MINUSONE_BENCHMARK_TRACK_LIMIT"], let value = Int(raw) {
            return value
        }
        return 5
    }

    func testBenchmarkAgainstMUSDB18() throws {
        try XCTSkipUnless(
            SeparationModelFactory.isAvailable(.balanced),
            "Separation model not downloaded — run Scripts/download-model.sh first."
        )

        let datasetRoot = Self.datasetRoot
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: datasetRoot.path, isDirectory: &isDirectory)
        try XCTSkipUnless(
            exists && isDirectory.boolValue,
            "No local MUSDB18 dump at \(datasetRoot.path) — run: python3 Scripts/fetch_musdb18.py --limit 5"
        )

        let trackDirs = try FileManager.default
            .contentsOfDirectory(at: datasetRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.trackLimit)

        try XCTSkipIf(trackDirs.isEmpty, "MUSDB18 dump directory is empty — run: python3 Scripts/fetch_musdb18.py --limit 5")

        let engine = OfflineSeparationEngine(libraryStore: libraryStore)
        var allScores: [SeparationStem: [Double]] = Dictionary(uniqueKeysWithValues: SeparationStem.allCases.map { ($0, []) })
        var tracksScored = 0

        for trackDir in trackDirs {
            let trackName = trackDir.lastPathComponent
            let mixURL = trackDir.appendingPathComponent("mixture.wav")
            guard FileManager.default.fileExists(atPath: mixURL.path) else {
                print("[SeparationQualityBenchmarkTests] skipping \(trackName): no mixture.wav")
                continue
            }

            let durationSeconds = try SeparationQualityHarness.duration(of: mixURL)
            let clip = PracticeClip(
                title: trackName,
                durationSeconds: durationSeconds,
                sourceHash: "musdb18-\(trackName)",
                sourceFileName: "mixture.wav",
                waveformPeaks: []
            )
            libraryStore.add(clip)

            // Real full-length tracks (or the 7s preview subset) take substantially longer than
            // the synthetic fixture's 18s clip — several minutes per track is expected on CPU.
            let finished = try SeparationQualityHarness.runSeparation(
                engine: engine, clip: clip, sourceURL: mixURL, timeout: 900
            )

            var trackReport: [String] = []
            for stem in SeparationStem.allCases {
                let referenceURL = trackDir.appendingPathComponent("\(stem.rawValue).wav")
                guard FileManager.default.fileExists(atPath: referenceURL.path),
                      let fileName = finished.stemFileNames[stem.rawValue] else { continue }
                let estimateURL = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)

                let reference = try SeparationQualityHarness.readStereo(referenceURL)
                let estimate = try SeparationQualityHarness.readStereo(estimateURL)
                let score = SeparationQualityHarness.siSDR(reference: reference, estimate: estimate)
                allScores[stem]?.append(score)
                trackReport.append("\(stem.rawValue)=\(String(format: "%.2f", score))dB")
            }
            tracksScored += 1
            print("[SeparationQualityBenchmarkTests] \(trackName): \(trackReport.joined(separator: ", "))")
        }

        try XCTSkipIf(tracksScored == 0, "No tracks had both a mixture.wav and matching reference stems to score")

        print("[SeparationQualityBenchmarkTests] --- mean SI-SDR over \(tracksScored) track(s) ---")
        for stem in SeparationStem.allCases {
            guard let values = allScores[stem], !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            print("[SeparationQualityBenchmarkTests] \(stem.rawValue): \(String(format: "%.2f", mean))dB")
        }
    }
}
