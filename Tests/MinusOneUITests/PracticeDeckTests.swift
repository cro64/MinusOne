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
        controller.playbackEngineForTesting.isolateStem(.vocals)

        controller.show(clip: second)
        controller.view.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let headers = descendants(of: controller.view).compactMap { $0 as? LaneHeaderView }
        XCTAssertEqual(headers.count, SeparationStem.allCases.count)
        // Assert against the engine rather than remembered literals. isolateStem(.vocals) mutes
        // every other stem and unmutes vocals — including the drums mute set just before it,
        // which isolate's "mute everyone else" reassigns rather than preserves.
        let mixer = controller.playbackEngineForTesting.mixer
        XCTAssertFalse(mixer.isMuted(.vocals))
        XCTAssertTrue(mixer.isMuted(.drums))
        XCTAssertTrue(mixer.isMuted(.bass))
        XCTAssertTrue(mixer.isMuted(.other))
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
        XCTAssertNil(controller.heroWaveformViewForTesting.loopRange, "the hero's loop band survived the switch")
    }

    /// One loop, two views: a loop drawn on the lanes must also appear on the hero, or the hero shows
    /// no loop while playback is wrapping.
    func testALoopDrawnOnTheLanesAlsoShowsOnTheHero() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        drawLoop(on: controller)

        let lanes = try XCTUnwrap(controller.timelineForTesting.loopRange, "the lane drag drew no band")
        XCTAssertEqual(controller.heroWaveformViewForTesting.loopRange, lanes)
    }

    /// The other direction, through the hero's real drag seams: the loop must engage the engine the
    /// same way a lane drag does, and appear on the lanes.
    func testALoopDrawnOnTheHeroEngagesAndShowsOnTheLanes() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        let hero = controller.heroWaveformViewForTesting
        let width = hero.bounds.width
        XCTAssertGreaterThan(width, 0, "premise: the hero has no width to drag across")

        hero.beginDrag(atX: width * 0.2)
        hero.continueDrag(toX: width * 0.5)
        hero.endDrag(atX: width * 0.5)

        let heroLoop = try XCTUnwrap(hero.loopRange, "the hero drag drew no band")
        XCTAssertTrue(controller.playbackEngineForTesting.isLoopEnabled, "the hero loop never engaged the engine")
        XCTAssertTrue(controller.isLoopButtonOnForTesting)
        XCTAssertEqual(controller.timelineForTesting.loopRange, heroLoop, "the lanes don't show the hero's loop")
        // 20% and 50% of a 60s clip. Within half a beat, in case a detected grid snapped the edges.
        XCTAssertEqual(heroLoop.lowerBound, 12, accuracy: 0.5)
        XCTAssertEqual(heroLoop.upperBound, 30, accuracy: 0.5)
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
        XCTAssertTrue(controller.toolbarForTesting.displayedBPMForTesting.isEmpty)
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
        controller.toolbarForTesting.commitBPMForTesting("96")

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
        controller.toolbarForTesting.commitBPMForTesting("96")

        let stored = try XCTUnwrap(libraryStore.clip(withID: clip.id))
        XCTAssertNil(stored.beatConfidence,
                     "kept the old detection's confidence \(String(describing: stored.beatConfidence)) on a hand-set grid")
    }

    /// Editing the tempo by hand still moves the deck's live grid (not just the persisted clip),
    /// and preserves the downbeat — this used to be `DeckTimelineView`'s own wiring before the
    /// toolbar moved into the controller alongside the rest of the transport.
    func testEditingTheTempoUpdatesTheLiveGrid() throws {
        var clip = try makeClip(withStemSidecars: true)
        clip.bpm = 120
        clip.downbeatOffsetSeconds = 0.5
        libraryStore.update(clip)

        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()
        controller.toolbarForTesting.commitBPMForTesting("96")

        let grid = try XCTUnwrap(controller.timelineForTesting.beatGrid)
        XCTAssertEqual(grid.bpm, 96, accuracy: 0.001)
        XCTAssertEqual(grid.downbeatOffsetSeconds, 0.5, accuracy: 0.001, "editing the tempo moved the downbeat")
    }

    /// Same clamp-divergence risk `DeckTimelineView` used to guard against, now that the toolbar
    /// and the grid it edits live on opposite sides of `PracticeDeckViewController`.
    func testTappingFasterThanTheGridAllowsLeavesTheFieldAgreeingWithTheGrid() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.layoutSubtreeIfNeeded()

        // Back-to-back, so the implied tempo is far above the grid's 400 BPM ceiling.
        controller.toolbarForTesting.tapForTesting()
        controller.toolbarForTesting.tapForTesting()

        let grid = try XCTUnwrap(controller.timelineForTesting.beatGrid)
        XCTAssertEqual(grid.bpm, 400, accuracy: 0.001, "fixture no longer exceeds the grid's clamp")
        XCTAssertEqual(controller.toolbarForTesting.displayedBPMForTesting, "400",
                       "the field shows a tempo the grid is not using")
    }

    /// The playback-speed slider used to stretch across the whole deck — the single heaviest
    /// element on the screen, and it duplicated the word "Tempo" already used by the BPM field.
    /// It's now a small, fixed-width control paired with BPM/Tap instead of its own full-width row.
    func testTheSpeedSliderIsNotFullWidth() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThan(controller.speedSliderForTesting.frame.width, 150,
                           "the speed slider is \(controller.speedSliderForTesting.frame.width)pt wide — still reads as a full-width row")
    }

    /// Spare window height goes to the lanes, but only a little — four slabs hundreds of points
    /// tall would stop reading as tracks.
    func testLanesGrowWithWindowHeightButStayCapped() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 562)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.timelineForTesting.laneHeight, TimelineMetrics.laneHeight, accuracy: 4,
                       "almost no spare height at the window floor, so lanes stay near their minimum")

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.heroHeightForTesting, HeroWaveformView.maximumHeight,
                             "spare height goes to the hero first")
        XCTAssertLessThan(controller.heroHeightForTesting,
                          HeroWaveformView.maximumHeight + HeroWaveformView.maximumExtraHeight)
        XCTAssertEqual(controller.timelineForTesting.laneHeight, TimelineMetrics.laneHeight, accuracy: 0.5,
                       "lanes wait until the hero is full")

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.heroHeightForTesting,
                       HeroWaveformView.maximumHeight + HeroWaveformView.maximumExtraHeight, accuracy: 0.5)
        let grown = controller.timelineForTesting.laneHeight
        XCTAssertGreaterThan(grown, TimelineMetrics.laneHeight)
        XCTAssertLessThan(grown, TimelineMetrics.maximumLaneHeight)

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.timelineForTesting.laneHeight, TimelineMetrics.maximumLaneHeight)
        XCTAssertEqual(controller.timelineForTesting.frame.height,
                       DeckTimelineView.height(forLaneCount: 4, laneHeight: TimelineMetrics.maximumLaneHeight), accuracy: 0.5)
        XCTAssertEqual(controller.heroHeightForTesting,
                       HeroWaveformView.maximumHeight + HeroWaveformView.maximumExtraHeight, accuracy: 0.5,
                       "a very tall window gives the hero its full extra height")
    }

    /// Growing for a big window (full screen) must not stick: the same deck shrinks back when the
    /// window does, all the way to the floor.
    func testTheDeckShrinksBackAfterAGrowingWindowShrinks() throws {
        let clip = try makeClip(withStemSidecars: true)
        let controller = deck()
        controller.show(clip: clip)

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 562)
        controller.view.layoutSubtreeIfNeeded()
        let floorHero = controller.heroHeightForTesting
        let floorLane = controller.timelineForTesting.laneHeight

        controller.view.frame = NSRect(x: 0, y: 0, width: 1470, height: 1600)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.heroHeightForTesting, floorHero + 100)

        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 562)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.heroHeightForTesting, floorHero, accuracy: 0.5)
        XCTAssertEqual(controller.timelineForTesting.laneHeight, floorLane, accuracy: 0.5)
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
