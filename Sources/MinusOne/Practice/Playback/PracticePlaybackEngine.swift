import AVFoundation

/// Plays a clip's separated stems in sync via `AVAudioEngine`: one `AVAudioPlayerNode` per stem,
/// each through its own `AVAudioUnitTimePitch` (shared rate, pitch fixed at 0) into the main mixer.
/// Playhead position is derived from the reference player's sample-accurate `playerTime`, which
/// tracks source-file frames consumed and is unaffected by downstream tempo stretching.
final class PracticePlaybackEngine {
    let mixer = StemMixerController()

    var onPlayheadUpdate: ((Double) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private var players: [SeparationStem: AVAudioPlayerNode] = [:]
    private var timePitches: [SeparationStem: AVAudioUnitTimePitch] = [:]
    private var files: [SeparationStem: AVAudioFile] = [:]
    private var referenceStem: SeparationStem?

    private var sampleRate: Double = 44_100
    private var totalDurationSeconds: Double = 0
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var hasScheduledSegment = false
    private(set) var isPlaying = false
    private var rate: Float = 1.0

    private var loopRangeSeconds: ClosedRange<Double>?
    var isLoopEnabled = false {
        didSet {
            guard oldValue != isLoopEnabled else { return }
            // Needed for the loop *button* (`toggleLoop()` in PracticeDeckViewController, which
            // flips this with no accompanying `seek`). Drawing or redrawing the loop region itself
            // always calls `seek(toSeconds:)` right after, which already reschedules correctly —
            // this covers the one call site that doesn't.
            rescheduleForLoopChange(resumeTime: currentTime(loopEnabled: oldValue, range: loopRangeSeconds))
        }
    }
    /// How many `[loopStartFrame, loopEndFrame)` loop-body iterations are scheduled on the players
    /// beyond the initial lead-in segment. Reset to 0 every time `scheduleSegment(fromFrame:)` runs.
    private var loopIterationsScheduled = 0

    private var pollTimer: Timer?

    // MARK: - Loading

    func load(clip: PracticeClip, libraryStore: ClipLibraryStore) throws {
        tearDown()

        var loadedFormat: AVAudioFormat?
        var maxFrames: AVAudioFrameCount = 0

        for stem in SeparationStem.allCases {
            guard let fileName = clip.stemFileNames[stem.rawValue] else { continue }
            let url = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { continue }

            files[stem] = file
            loadedFormat = file.processingFormat
            maxFrames = max(maxFrames, AVAudioFrameCount(file.length))

            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            timePitch.rate = rate
            timePitch.pitch = 0
            engine.attach(player)
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)

            players[stem] = player
            timePitches[stem] = timePitch
            player.volume = mixer.effectiveVolume(for: stem)
            if referenceStem == nil { referenceStem = stem }
        }

        guard let loadedFormat, maxFrames > 0 else {
            throw PlaybackError.noPlayableStems
        }

        sampleRate = loadedFormat.sampleRate
        totalDurationSeconds = Double(maxFrames) / sampleRate
        segmentStartFrame = 0
        hasScheduledSegment = false

        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Re-reads stem files (picking up newly-flushed audio as background separation advances)
    /// while preserving playhead position and play/pause state.
    func reload(clip: PracticeClip, libraryStore: ClipLibraryStore) throws {
        let resumeTime = currentTime()
        let wasPlaying = isPlaying
        try load(clip: clip, libraryStore: libraryStore)
        seek(toSeconds: resumeTime)
        if wasPlaying { play() }
    }

    enum PlaybackError: Error, LocalizedError {
        case noPlayableStems
        var errorDescription: String? {
            "No separated stems are ready to play yet."
        }
    }

    // MARK: - Transport

    func play() {
        guard !players.isEmpty else { return }
        if !hasScheduledSegment {
            scheduleSegment(fromFrame: segmentStartFrame)
        }
        for player in players.values { player.play() }
        isPlaying = true
        startPolling()
    }

    func pause() {
        for player in players.values { player.pause() }
        isPlaying = false
        stopPolling()
    }

    func seek(toSeconds seconds: Double) {
        let wasPlaying = isPlaying
        for player in players.values { player.stop() }
        let clamped = min(max(0, seconds), totalDurationSeconds)
        segmentStartFrame = AVAudioFramePosition(clamped * sampleRate)
        scheduleSegment(fromFrame: segmentStartFrame)
        if wasPlaying {
            for player in players.values { player.play() }
            isPlaying = true
        }
        onPlayheadUpdate?(clamped)
    }

    func setTempo(_ newRate: Float) {
        rate = min(1.0, max(0.5, newRate))
        for timePitch in timePitches.values { timePitch.rate = rate }
    }

    func setLoopRange(_ range: ClosedRange<Double>?) {
        loopRangeSeconds = range
    }

    func duration() -> Double { totalDurationSeconds }

    // MARK: - Mixer passthrough

    func setStemVolume(_ volume: Float, for stem: SeparationStem) {
        mixer.setVolume(volume, for: stem)
        applyVolumes()
    }

    func setStemMuted(_ muted: Bool, for stem: SeparationStem) {
        mixer.setMuted(muted, for: stem)
        applyVolumes()
    }

    func toggleStemSolo(_ stem: SeparationStem) {
        mixer.toggleSolo(stem)
        applyVolumes()
    }

    private func applyVolumes() {
        for (stem, player) in players {
            player.volume = mixer.effectiveVolume(for: stem)
        }
    }

    // MARK: - Playhead

    func currentTime() -> Double {
        currentTime(loopEnabled: isLoopEnabled, range: loopRangeSeconds)
    }

    /// Takes loop config as parameters, rather than reading `isLoopEnabled`/`loopRangeSeconds`
    /// directly, so a loop-config change can compute the playhead under the *old* configuration
    /// before it's overwritten (see `isLoopEnabled`'s `didSet` above).
    private func currentTime(loopEnabled: Bool, range: ClosedRange<Double>?) -> Double {
        guard let referenceStem, let player = players[referenceStem],
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else {
            return Double(segmentStartFrame) / sampleRate
        }
        let position = Self.filePosition(
            elapsedSampleTime: playerTime.sampleTime,
            segmentStartFrame: segmentStartFrame,
            loopEnabled: loopEnabled,
            range: range,
            sampleRate: sampleRate
        )
        return min(totalDurationSeconds, Double(position) / sampleRate)
    }

    // MARK: - Loop position math

    /// Maps the player's own continuously-increasing sample clock back to a position within the
    /// file, wrapping modulo the loop length once a loop is engaged.
    ///
    /// Pure and parameterized (not reading instance state directly) so it is testable without a
    /// running `AVAudioEngine` — a real one crashes outright in this project's test environment.
    /// Internal rather than private for the same reason `OfflineSeparationEngine.withCurrentBeatGrid`
    /// is: so `PracticePlaybackEngineLoopMathTests` can pin it directly.
    static func filePosition(
        elapsedSampleTime: AVAudioFramePosition,
        segmentStartFrame: AVAudioFramePosition,
        loopEnabled: Bool,
        range: ClosedRange<Double>?,
        sampleRate: Double
    ) -> AVAudioFramePosition {
        guard loopEnabled, let range else {
            return segmentStartFrame + elapsedSampleTime
        }
        let loopStartFrame = AVAudioFramePosition(range.lowerBound * sampleRate)
        let loopEndFrame = AVAudioFramePosition(range.upperBound * sampleRate)
        guard loopEndFrame > loopStartFrame else {
            return segmentStartFrame + elapsedSampleTime
        }
        let leadInLength = loopEndFrame - segmentStartFrame
        guard elapsedSampleTime >= leadInLength else {
            return segmentStartFrame + elapsedSampleTime
        }
        let loopLength = loopEndFrame - loopStartFrame
        let sinceLoopStart = (elapsedSampleTime - leadInLength) % loopLength
        return loopStartFrame + sinceLoopStart
    }

    // MARK: - Internals

    private func frame(forSeconds seconds: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(seconds * sampleRate)
    }

    private func scheduleSegment(fromFrame startFrame: AVAudioFramePosition) {
        loopIterationsScheduled = 0
        if isLoopEnabled, let loopRangeSeconds {
            let loopStartFrame = frame(forSeconds: loopRangeSeconds.lowerBound)
            let loopEndFrame = frame(forSeconds: loopRangeSeconds.upperBound)
            if loopEndFrame > loopStartFrame, startFrame >= loopStartFrame, startFrame < loopEndFrame {
                scheduleLoopLeadIn(fromFrame: startFrame, loopEndFrame: loopEndFrame)
                scheduleNextLoopIterationIfNeeded()
                hasScheduledSegment = true
                return
            }
        }
        for (stem, player) in players {
            guard let file = files[stem] else { continue }
            let clampedStart = min(max(0, startFrame), file.length)
            let framesToPlay = AVAudioFrameCount(max(0, file.length - clampedStart))
            guard framesToPlay > 0 else { continue }
            player.scheduleSegment(file, startingFrame: clampedStart, frameCount: framesToPlay, at: nil)
        }
        hasScheduledSegment = true
    }

    /// Schedules only up to `loopEndFrame` — the segment that plays from wherever we're starting
    /// until the loop's own end, immediately (`at: nil`). `scheduleNextLoopIterationIfNeeded()`
    /// queues the loop body that continues gaplessly from there.
    private func scheduleLoopLeadIn(fromFrame startFrame: AVAudioFramePosition, loopEndFrame: AVAudioFramePosition) {
        for (stem, player) in players {
            guard let file = files[stem] else { continue }
            let clampedStart = min(max(0, startFrame), file.length)
            let clampedEnd = min(max(clampedStart, loopEndFrame), file.length)
            let framesToPlay = AVAudioFrameCount(max(0, clampedEnd - clampedStart))
            guard framesToPlay > 0 else { continue }
            player.scheduleSegment(file, startingFrame: clampedStart, frameCount: framesToPlay, at: nil)
        }
    }

    /// Keeps exactly one loop-body iteration `[loopStartFrame, loopEndFrame)` queued ahead of the
    /// one currently playing, chained on the still-playing node via `scheduleSegment(..., at:)`
    /// with an explicit future `AVAudioTime` — never `stop()`, which is what made every previous
    /// wrap tear playback down. Validated in the Task 2 measurement harness (spec §12, "Measured
    /// 2026-09-02"): a segment scheduled this way joins the currently-playing one sample-accurately.
    ///
    /// Called once unconditionally right after the lead-in is scheduled (`loopIterationsScheduled
    /// == 0`, so no live player timing is needed yet — we're declaring a future start time, not
    /// reading the current position), and from every `tick()` afterward to top up once the most
    /// recently queued iteration has actually started playing.
    private func scheduleNextLoopIterationIfNeeded() {
        guard isLoopEnabled, let loopRangeSeconds else { return }
        let loopStartFrame = frame(forSeconds: loopRangeSeconds.lowerBound)
        let loopEndFrame = frame(forSeconds: loopRangeSeconds.upperBound)
        guard loopEndFrame > loopStartFrame else { return }

        let loopLength = loopEndFrame - loopStartFrame
        let leadInLength = loopEndFrame - segmentStartFrame

        if loopIterationsScheduled > 0 {
            guard let referenceStem, let player = players[referenceStem],
                  let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
                  let playerTime = player.playerTime(forNodeTime: nodeTime)
            else { return }
            let lastScheduledIterationStart = leadInLength + AVAudioFramePosition(loopIterationsScheduled - 1) * loopLength
            guard playerTime.sampleTime >= lastScheduledIterationStart else { return }
        }

        let nextIterationSampleTime = leadInLength + AVAudioFramePosition(loopIterationsScheduled) * loopLength
        let nextIterationStart = AVAudioTime(sampleTime: nextIterationSampleTime, atRate: sampleRate)
        for (stem, player) in players {
            guard let file = files[stem] else { continue }
            let clampedLoopEnd = min(loopEndFrame, file.length)
            guard clampedLoopEnd > loopStartFrame else { continue }
            let framesToPlay = AVAudioFrameCount(clampedLoopEnd - loopStartFrame)
            player.scheduleSegment(file, startingFrame: loopStartFrame, frameCount: framesToPlay, at: nextIterationStart)
        }
        loopIterationsScheduled += 1
    }

    /// Rebuilds scheduling from the current playhead when looping is turned on or off outside a
    /// `seek` — the loop button (`toggleLoop()`), rather than drawing or redrawing the loop region,
    /// which already calls `seek` itself and reschedules correctly through the normal path.
    ///
    /// A loop being switched on or off is a discrete, one-off event, not the steady-state repeat
    /// this phase pre-schedules gaplessly, so falling back to the same stop/reschedule/play
    /// sequence `seek` uses is an acceptable, single small discontinuity here — not the "gaps
    /// audibly on every wrap" bug this phase fixes.
    private func rescheduleForLoopChange(resumeTime: Double) {
        guard hasScheduledSegment else { return }
        let wasPlaying = isPlaying
        var target = resumeTime
        if isLoopEnabled, let loopRangeSeconds, !loopRangeSeconds.contains(target) {
            target = loopRangeSeconds.lowerBound
        }
        for player in players.values { player.stop() }
        segmentStartFrame = frame(forSeconds: min(max(0, target), totalDurationSeconds))
        scheduleSegment(fromFrame: segmentStartFrame)
        if wasPlaying {
            for player in players.values { player.play() }
            isPlaying = true
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        scheduleNextLoopIterationIfNeeded()
        let time = currentTime()

        if time >= totalDurationSeconds - 0.02 {
            pause()
            segmentStartFrame = 0
            hasScheduledSegment = false
            onPlayheadUpdate?(0)
            onPlaybackFinished?()
            return
        }

        onPlayheadUpdate?(time)
    }

    private func tearDown() {
        stopPolling()
        for player in players.values {
            player.stop()
            engine.detach(player)
        }
        for timePitch in timePitches.values {
            engine.detach(timePitch)
        }
        players.removeAll()
        timePitches.removeAll()
        files.removeAll()
        referenceStem = nil
        isPlaying = false
        hasScheduledSegment = false
        segmentStartFrame = 0
        loopIterationsScheduled = 0
    }
}
