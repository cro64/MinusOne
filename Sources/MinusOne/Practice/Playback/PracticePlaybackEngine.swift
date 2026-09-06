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
        var clamped = min(max(0, seconds), totalDurationSeconds)
        // Keeps segmentStartFrame inside the loop whenever looping is active — the invariant
        // scheduleNextLoopIterationIfNeeded() and filePosition() both depend on. Mirrors the same
        // corralling rescheduleForLoopChange() does when the loop config itself changes; here it's
        // needed because a plain seek (a timeline tap, or the skip-forward/back buttons) can also
        // land outside the loop while isLoopEnabled/loopRangeSeconds stay untouched.
        if isLoopEnabled, let loopRangeSeconds, !Self.isFrameInsideLoopRange(clamped, range: loopRangeSeconds, sampleRate: sampleRate) {
            clamped = loopRangeSeconds.lowerBound
        }
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

    func isolateStem(_ stem: SeparationStem) {
        mixer.isolateStem(stem)
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

    /// True when `seconds`, converted to frames at `sampleRate`, falls inside
    /// `[range.lowerBound, range.upperBound)` — the same half-open test `scheduleSegment(fromFrame:)`'s
    /// loop branch uses. Deliberately not `ClosedRange<Double>.contains`, which is inclusive of
    /// `upperBound` and would let a target landing exactly there slip past uncorralled, producing
    /// `segmentStartFrame == loopEndFrame` — outside the loop-participating range `filePosition` and
    /// `scheduleNextLoopIterationIfNeeded()` both assume. `static` for the same reason `filePosition`
    /// is: testable without a running `AVAudioEngine`.
    static func isFrameInsideLoopRange(_ seconds: Double, range: ClosedRange<Double>, sampleRate: Double) -> Bool {
        let loopStartFrame = AVAudioFramePosition(range.lowerBound * sampleRate)
        let loopEndFrame = AVAudioFramePosition(range.upperBound * sampleRate)
        guard loopEndFrame > loopStartFrame else { return false }
        let target = AVAudioFramePosition(seconds * sampleRate)
        return target >= loopStartFrame && target < loopEndFrame
    }

    /// The sample-time starts of the loop-body iterations that should be queued next, given how many
    /// are already scheduled and the current player position — enough that at least `lookaheadFrames`
    /// of source frames stay banked ahead of `currentPlayerSampleTime` at all times. For an ordinary
    /// multi-second loop this returns a single sample time (the very next one already clears the
    /// lookahead bar), but a loop shorter than `lookaheadFrames` returns several, so a short loop
    /// keeps real margin banked against a late `tick()`.
    ///
    /// `currentPlayerSampleTime == nil` means no live player timing is available yet — the very first
    /// iteration, queued right after the lead-in and before playback has actually started — and always
    /// yields exactly one candidate, matching the original (pre-lookahead) behavior for that case.
    ///
    /// Pure and static so it's testable without a running `AVAudioEngine`, same as
    /// `filePosition`/`isFrameInsideLoopRange`. `scheduleNextLoopIterationIfNeeded()` is the sole
    /// caller and performs the actual `AVAudioPlayerNode` scheduling this only describes.
    static func loopIterationsToSchedule(
        alreadyScheduled: Int,
        leadInLength: AVAudioFramePosition,
        loopLength: AVAudioFramePosition,
        currentPlayerSampleTime: AVAudioFramePosition?,
        lookaheadFrames: AVAudioFramePosition
    ) -> [AVAudioFramePosition] {
        guard loopLength > 0 else { return [] }
        var sampleTimes: [AVAudioFramePosition] = []
        var index = alreadyScheduled
        while true {
            let nextIterationSampleTime = leadInLength + AVAudioFramePosition(index) * loopLength
            if let currentPlayerSampleTime, nextIterationSampleTime >= currentPlayerSampleTime + lookaheadFrames {
                break
            }
            sampleTimes.append(nextIterationSampleTime)
            index += 1
            if currentPlayerSampleTime == nil { break }
        }
        return sampleTimes
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

    /// Keeps loop-body iterations `[loopStartFrame, loopEndFrame)` queued ahead of the one currently
    /// playing, chained on the still-playing node via `scheduleSegment(..., at:)` with an explicit
    /// future `AVAudioTime` — never `stop()`, which is what made every previous wrap tear playback
    /// down. Validated in the Task 2 measurement harness (spec §12, "Measured 2026-09-02"): a segment
    /// scheduled this way joins the currently-playing one sample-accurately.
    ///
    /// Tops up with a ~1-second time-based lookahead (`Self.loopIterationsToSchedule`) rather than
    /// "exactly one iteration ahead": for an ordinary multi-second loop this still queues exactly one
    /// iteration per call, same as scheduling only once the previous one had already started, since
    /// the very next not-yet-queued iteration already clears the 1-second bar on its own. But a
    /// one-iteration margin was only as safe as the 50ms poll timer never running late — for a short
    /// loop (well under a second) a main-thread stall (a sheet presenting, a relayout, a completion
    /// handler doing real work) could eat that margin entirely, and unlike the pre-Phase-4
    /// stop/reschedule/play code (where a late tick just meant audible overshoot), a late tick here
    /// could produce actual silence at the wrap. `loopIterationsToSchedule` instead keeps queuing —
    /// each `loopLength` further along than the last — until the most recently queued iteration starts
    /// at least a second of source frames ahead of the current player position, so a short loop
    /// naturally ends up with several iterations banked instead of one.
    ///
    /// Called once unconditionally right after the lead-in is scheduled (`loopIterationsScheduled
    /// == 0`, so no live player timing is needed yet — we're declaring a future start time, not
    /// reading the current position), and from every `tick()` afterward to top up as needed.
    private func scheduleNextLoopIterationIfNeeded() {
        guard isLoopEnabled, let loopRangeSeconds else { return }
        let loopStartFrame = frame(forSeconds: loopRangeSeconds.lowerBound)
        let loopEndFrame = frame(forSeconds: loopRangeSeconds.upperBound)
        guard loopEndFrame > loopStartFrame else { return }

        let loopLength = loopEndFrame - loopStartFrame
        let leadInLength = loopEndFrame - segmentStartFrame

        var currentPlayerSampleTime: AVAudioFramePosition?
        if loopIterationsScheduled > 0 {
            guard let referenceStem, let player = players[referenceStem],
                  let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
                  let playerTime = player.playerTime(forNodeTime: nodeTime)
            else { return }
            currentPlayerSampleTime = playerTime.sampleTime
        }

        let sampleTimesToSchedule = Self.loopIterationsToSchedule(
            alreadyScheduled: loopIterationsScheduled,
            leadInLength: leadInLength,
            loopLength: loopLength,
            currentPlayerSampleTime: currentPlayerSampleTime,
            lookaheadFrames: AVAudioFramePosition(sampleRate) // ~1 second of source frames
        )
        guard !sampleTimesToSchedule.isEmpty else { return }

        // Whether a given stem can be scheduled at all (does its file currently reach the loop?)
        // doesn't vary across the candidate sample times above — same `files`, same loop bounds for
        // all of them in this one call — so a single players loop, scheduling every candidate time
        // per player, is equivalent to (and cheaper than) re-checking per iteration.
        var scheduledAny = false
        for (stem, player) in players {
            guard let file = files[stem] else { continue }
            let clampedLoopEnd = min(loopEndFrame, file.length)
            guard clampedLoopEnd > loopStartFrame else { continue }
            let framesToPlay = AVAudioFrameCount(clampedLoopEnd - loopStartFrame)
            for sampleTime in sampleTimesToSchedule {
                let at = AVAudioTime(sampleTime: sampleTime, atRate: sampleRate)
                player.scheduleSegment(file, startingFrame: loopStartFrame, frameCount: framesToPlay, at: at)
            }
            scheduledAny = true
        }
        // Only counts as queued once at least one player was actually given a segment — a stem
        // whose file doesn't yet reach the loop must not silently inflate the count while
        // contributing nothing.
        if scheduledAny {
            loopIterationsScheduled += sampleTimesToSchedule.count
        }
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
        if isLoopEnabled, let loopRangeSeconds, !Self.isFrameInsideLoopRange(target, range: loopRangeSeconds, sampleRate: sampleRate) {
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

        // A genuinely active loop never "finishes" — it loops until disabled or stopped, regardless
        // of where its end falls relative to totalDurationSeconds. Without this guard, a loop whose
        // end is at or past the clip's ready/total duration would hit the finished branch below on
        // every tick (currentTime()'s clamp pins `time` at totalDurationSeconds), which is worse than
        // just missing a wrap: scheduleNextLoopIterationIfNeeded() above may have just queued another
        // iteration at a future player sample time, and pause() doesn't stop the players or reset
        // their timeline — so the queued segment stays pending while segmentStartFrame resets to 0
        // out from under it.
        let isActivelyLooping = isLoopEnabled && loopRangeSeconds != nil
        if !isActivelyLooping, time >= totalDurationSeconds - 0.02 {
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
