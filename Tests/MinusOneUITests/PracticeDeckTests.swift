import AVFoundation
import AppKit
import XCTest
@testable import MinusOne

/// The deck's clip-lifecycle wiring. Playback is never started here: a clip with
/// `readyDurationSeconds == 0` makes `loadPlaybackIfPossible` return before it touches
/// `AVAudioEngine`, so these run with no audio device.
final class PracticeDeckTests: XCTestCase {
    private var root: URL!
    private var libraryStore: ClipLibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PracticeDeck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        libraryStore = ClipLibraryStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeClip(withStemSidecars: Bool) throws -> PracticeClip {
        let clip = PracticeClip(
            title: "Test",
            durationSeconds: 60,
            sourceHash: "hash",
            sourceFileName: "source.caf",
            waveformPeaks: [Float](repeating: 0.5, count: 1200)
        )
        libraryStore.update(clip)
        let peaks = try libraryStore.ensurePeaksFolder(forClipID: clip.id)

        var tracks: [PeakTrack] = [.mix]
        if withStemSidecars { tracks += SeparationStem.allCases.map(PeakTrack.stem) }
        for track in tracks {
            let writer = try PeakSidecarWriter(url: peaks.appendingPathComponent(track.fileName), sampleRate: 44_100)
            try writer.append([Float](repeating: 0.7, count: 60 * 44_100))
            try writer.finish()
        }
        return clip
    }

    private func deck() -> PracticeDeckViewController {
        let controller = PracticeDeckViewController(libraryStore: libraryStore, playbackEngine: PracticePlaybackEngine())
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 700)
        return controller
    }

    func testShowingASeparatedClipFillsTheTimeline() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.timelineForTesting.tracks, SeparationStem.allCases.map(PeakTrack.stem))
        XCTAssertEqual(controller.timelineForTesting.viewport.clipDuration, 60, accuracy: 0.001)
    }

    func testShowingAnUnseparatedClipFallsBackToTheMixLane() throws {
        let clip = try makeClip(withStemSidecars: false)
        let controller = deck()
        controller.show(clip: clip)
        XCTAssertEqual(controller.timelineForTesting.tracks, [.mix])
    }

    /// The old waveform-and-mixer deck is gone, not merely hidden behind the new one.
    func testTheOldWaveformAndMixerAreNotInTheViewTree() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let all = descendants(of: controller.view)
        XCTAssertFalse(all.contains { $0 is WaveformView }, "the stretched deck waveform is still there")
        XCTAssertEqual(all.filter { $0 is DeckTimelineView }.count, 1)
    }

    /// Every stem's controls must still be reachable — the lane headers are the only place the
    /// fader, mute, solo and export live now that the "Stems" section is gone.
    func testEveryStemStillHasItsOwnControls() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let headers = descendants(of: controller.view).compactMap { $0 as? LaneHeaderView }
        XCTAssertEqual(headers.count, SeparationStem.allCases.count)
    }

    /// The migrator shipped in the previous phase with no caller. It is called from here now.
    func testShowingAClipWithoutSidecarsBackfillsThem() throws {
        var clip = try makeClip(withStemSidecars: false)
        // A clip that predates the format: audio on disk, no peaks anywhere.
        try FileManager.default.removeItem(at: libraryStore.peaksFolder(forClipID: clip.id))
        let source = libraryStore.stemFileURL(clipID: clip.id, fileName: clip.sourceFileName)
        try writeSilentAudio(to: source, seconds: 2)
        clip.peakFileNames = [:]
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)

        let url = libraryStore.peakFileURL(clipID: clip.id, track: .mix)
        let expectation = XCTestExpectation(description: "mix sidecar backfilled")
        DispatchQueue.global().async {
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: url.path) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the migrator never wrote the mix sidecar")
    }

    /// The mixer outlives any one clip, but lane headers are rebuilt per clip. Without a re-push a
    /// stem muted on one clip stays silent on the next with nothing in the UI to say so.
    func testMixerStateSurvivesAClipSwitch() throws {
        let first = try makeClip(withStemSidecars: true)
        let second = try makeClip(withStemSidecars: true)
        let controller = deck()

        controller.show(clip: first)
        controller.view.layoutSubtreeIfNeeded()
        controller.playbackEngineForTesting.setStemMuted(true, for: .drums)
        controller.playbackEngineForTesting.setStemVolume(0.25, for: .bass)
        controller.playbackEngineForTesting.toggleStemSolo(.vocals)

        controller.show(clip: second)
        controller.view.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let headers = descendants(of: controller.view).compactMap { $0 as? LaneHeaderView }
        XCTAssertEqual(headers.count, SeparationStem.allCases.count)
        // Assert against the engine rather than remembered literals.
        let mixer = controller.playbackEngineForTesting.mixer
        XCTAssertTrue(mixer.isMuted(.drums))
        XCTAssertTrue(mixer.isSoloed(.vocals))
        XCTAssertEqual(mixer.volume(for: .bass), 0.25, accuracy: 0.001)

        // The half that actually fails without the fix: the rebuilt UI must match the mixer, not
        // just the engine (which was never in doubt — nothing in this test touches it).
        let headersByStem = controller.timelineForTesting.headersForTesting
        for stem in SeparationStem.allCases {
            guard let header = headersByStem[stem] else {
                XCTFail("no header found for \(stem)")
                continue
            }
            XCTAssertEqual(header.isMutedForTesting, mixer.isMuted(stem), "\(stem) mute UI")
            XCTAssertEqual(header.isSoloedForTesting, mixer.isSoloed(stem), "\(stem) solo UI")
            XCTAssertEqual(header.volumeForTesting, mixer.volume(for: stem), accuracy: 0.001, "\(stem) volume UI")
        }
    }

    /// A loop belongs to the clip it was drawn on. The engine's teardown deliberately keeps
    /// `loopRangeSeconds`/`isLoopEnabled` (it also runs on every separation tick, where wiping a
    /// loop mid-practice would be worse), so the deck has to drop it when the clip changes —
    /// otherwise playback keeps wrapping at a time the new clip never shows.
    func testTheLoopIsDroppedWhenTheClipChanges() throws {
        let first = try makeClip(withStemSidecars: true)
        let second = try makeClip(withStemSidecars: true)
        let controller = deck()

        controller.show(clip: first)
        controller.view.layoutSubtreeIfNeeded()

        // Drawn the way the user draws one: the real drag seams, which set the band *and* fire the
        // callback. Invoking `onLoopRangeChanged` alone only notifies the deck — it leaves the
        // timeline's own band unset, which is not the state a clip switch has to clean up.
        drawLoop(on: controller)
        XCTAssertTrue(controller.playbackEngineForTesting.isLoopEnabled, "the loop never engaged")
        XCTAssertTrue(controller.isLoopButtonOnForTesting)
        XCTAssertNotNil(controller.timelineForTesting.loopRange)

        controller.show(clip: second)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.playbackEngineForTesting.isLoopEnabled,
                       "the engine still loops a range belonging to the previous clip")
        XCTAssertFalse(controller.isLoopButtonOnForTesting, "the Loop button still reads on")
        XCTAssertNil(controller.timelineForTesting.loopRange, "the loop band survived the switch")
    }

    /// The counterpart: a separation tick must *not* drop a loop the user just drew. `updateClip`
    /// routes through `reload`, which tears the engine down — so a reset placed there instead of at
    /// the clip switch would wipe the loop every couple of seconds while a clip separates.
    func testASeparationTickDoesNotDropTheLoop() throws {
        var clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        drawLoop(on: controller)
        XCTAssertTrue(controller.playbackEngineForTesting.isLoopEnabled)
        XCTAssertNotNil(controller.timelineForTesting.loopRange, "the drag never drew a band")

        // What a separation flush looks like to the deck: same clip, more audio ready.
        clip.readyDurationSeconds = 30
        controller.updateClip(clip)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.playbackEngineForTesting.isLoopEnabled,
                      "a separation tick dropped the user's loop")
        XCTAssertNotNil(controller.timelineForTesting.loopRange)
    }

    /// Draws a loop through the timeline's real drag seams, so the band and the engine end up in
    /// the same state a user's drag leaves them in.
    private func drawLoop(on controller: PracticeDeckViewController) {
        let timeline = controller.timelineForTesting
        timeline.beginCanvasDrag(atX: 100)
        timeline.continueCanvasDrag(toX: 400)
        timeline.endCanvasDrag(atX: 400)
    }

    private func writeSilentAudio(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![0][frame] = sinf(Float(frame) * 0.01) * 0.5
            }
            try file.write(from: buffer)
        }
    }

    /// A drums stem with periodic transients at a known tempo, written directly so
    /// `detectBeatGrid` has real audio to detect against.
    ///
    /// Deliberately never sets `readyDurationSeconds` above its default 0 in the tests that use
    /// this: `loadPlaybackIfPossible` gates on that before touching `PracticePlaybackEngine.load()`,
    /// and `AVAudioEngine.start()` crashes outright in this test environment (no audio device).
    private func writeDrumBeat(to url: URL, bpm: Double, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            let beat = 60 / bpm * 44_100
            var position = 0.5 * 44_100
            var index = 0
            while position < Double(frames) {
                let start = Int(position)
                let amplitude: Float = index % 4 == 0 ? 0.95 : 0.4
                for offset in 0..<220 where start + offset < Int(frames) {
                    buffer.floatChannelData![0][start + offset] = amplitude * (1 - Float(offset) / 220)
                }
                position += beat
                index += 1
            }
            try file.write(from: buffer)
        }
    }

    /// Spec §9: an existing clip that predates the sidecar format gets no beat grid until it is
    /// separated again, because `detectBeatGrid`'s only trigger was separation finishing. The
    /// migration backfill is the other place a clip's audio is already read from disk — the hook
    /// belongs there.
    func testShowingAClipWithoutSidecarsAlsoDetectsItsBeatGrid() throws {
        var clip = try makeClip(withStemSidecars: false)
        try FileManager.default.removeItem(at: libraryStore.peaksFolder(forClipID: clip.id))
        let source = libraryStore.stemFileURL(clipID: clip.id, fileName: clip.sourceFileName)
        try writeSilentAudio(to: source, seconds: 20)
        let drumsURL = libraryStore.stemFileURL(clipID: clip.id, fileName: "drums.caf")
        try writeDrumBeat(to: drumsURL, bpm: 120, seconds: 20)
        clip.stemFileNames = [SeparationStem.drums.rawValue: "drums.caf"]
        clip.peakFileNames = [:]
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)

        let expectation = XCTestExpectation(description: "migration backfill completed")
        DispatchQueue.global().async {
            for _ in 0..<200 where self.libraryStore.clip(withID: clip.id)?.peakFileNames["mix"] == nil {
                Thread.sleep(forTimeInterval: 0.05)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)

        let stored = try XCTUnwrap(libraryStore.clip(withID: clip.id))
        let bpm = try XCTUnwrap(stored.bpm)
        XCTAssertEqual(bpm, 120, accuracy: 3)
        XCTAssertFalse(stored.isBeatGridUserSet)
    }

    /// A user-set grid must survive a migration backfill exactly like it survives separation
    /// (`BeatDetectionWiringTests.testItRefusesToOverwriteAUserSetGrid` pins the same rule for
    /// `detectBeatGrid` directly).
    func testShowingAClipWithAUserSetGridDoesNotOverwriteItDuringMigration() throws {
        var clip = try makeClip(withStemSidecars: false)
        try FileManager.default.removeItem(at: libraryStore.peaksFolder(forClipID: clip.id))
        let source = libraryStore.stemFileURL(clipID: clip.id, fileName: clip.sourceFileName)
        try writeSilentAudio(to: source, seconds: 20)
        let drumsURL = libraryStore.stemFileURL(clipID: clip.id, fileName: "drums.caf")
        try writeDrumBeat(to: drumsURL, bpm: 120, seconds: 20)
        clip.stemFileNames = [SeparationStem.drums.rawValue: "drums.caf"]
        clip.peakFileNames = [:]
        clip.bpm = 97
        clip.downbeatOffsetSeconds = 1.25
        clip.isBeatGridUserSet = true
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)

        let expectation = XCTestExpectation(description: "migration backfill completed")
        DispatchQueue.global().async {
            for _ in 0..<200 where self.libraryStore.clip(withID: clip.id)?.peakFileNames["mix"] == nil {
                Thread.sleep(forTimeInterval: 0.05)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)

        let stored = try XCTUnwrap(libraryStore.clip(withID: clip.id))
        XCTAssertEqual(stored.bpm, 97)
        XCTAssertEqual(stored.downbeatOffsetSeconds, 1.25)
        XCTAssertTrue(stored.isBeatGridUserSet)
    }

    func testAClipWithADetectedGridShowsIt() throws {
        var clip = try makeClip(withStemSidecars: true)
        clip.bpm = 128
        clip.downbeatOffsetSeconds = 0.75
        clip.beatConfidence = 9
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        let grid = try XCTUnwrap(controller.timelineForTesting.beatGrid)
        XCTAssertEqual(grid.bpm, 128, accuracy: 0.001)
        XCTAssertEqual(grid.downbeatOffsetSeconds, 0.75, accuracy: 0.001)
    }

    /// Spec §6: below the threshold the grid is suppressed, so a clip with no stored tempo shows
    /// the clock ruler and an empty field.
    func testAClipWithNoGridShowsNone() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        XCTAssertNil(controller.timelineForTesting.beatGrid)
        XCTAssertTrue(controller.timelineForTesting.toolbarForTesting.displayedBPMForTesting.isEmpty)
    }

    /// The rule the whole `isBeatGridUserSet` boolean exists for.
    func testEditingTheTempoPersistsItAsAUserSetGrid() throws {
        var clip = try makeClip(withStemSidecars: true)
        clip.bpm = 128
        clip.downbeatOffsetSeconds = 0.5
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()
        controller.timelineForTesting.toolbarForTesting.commitBPMForTesting("96")

        let stored = try XCTUnwrap(libraryStore.clip(withID: clip.id))
        XCTAssertEqual(try XCTUnwrap(stored.bpm), 96, accuracy: 0.001)
        XCTAssertTrue(stored.isBeatGridUserSet, "a hand-set tempo was not marked as user-set")
    }

    /// A confidence measures a detection. Once the grid is hand-set the stored figure describes a
    /// tempo that is no longer on the clip, and leaving it attached writes a lie to the index —
    /// nothing reads it at runtime today, which is exactly why it would go unnoticed.
    func testAHandSetGridClearsTheDetectionConfidence() throws {
        var clip = try makeClip(withStemSidecars: true)
        clip.bpm = 128
        clip.downbeatOffsetSeconds = 0.5
        clip.beatConfidence = 21.5
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()
        controller.timelineForTesting.toolbarForTesting.commitBPMForTesting("96")

        let stored = try XCTUnwrap(libraryStore.clip(withID: clip.id))
        XCTAssertNil(stored.beatConfidence,
                     "kept the old detection's confidence \(String(describing: stored.beatConfidence)) on a hand-set grid")
    }

    /// A grid must not follow the user to the next clip — each clip has its own.
    func testTheGridIsReplacedOnAClipSwitch() throws {
        var first = try makeClip(withStemSidecars: true)
        first.bpm = 128
        first.downbeatOffsetSeconds = 0.5
        libraryStore.update(first)
        let second = try makeClip(withStemSidecars: true)

        let controller = deck()
        controller.show(clip: first)
        XCTAssertNotNil(controller.timelineForTesting.beatGrid)

        controller.show(clip: second)
        XCTAssertNil(controller.timelineForTesting.beatGrid, "the previous clip's grid survived the switch")
    }
}
