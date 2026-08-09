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
    var isLoopEnabled = false

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
        guard let referenceStem, let player = players[referenceStem],
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else {
            return Double(segmentStartFrame) / sampleRate
        }
        return min(totalDurationSeconds, Double(segmentStartFrame) / sampleRate + Double(playerTime.sampleTime) / sampleRate)
    }

    // MARK: - Internals

    private func scheduleSegment(fromFrame startFrame: AVAudioFramePosition) {
        for (stem, player) in players {
            guard let file = files[stem] else { continue }
            let clampedStart = min(max(0, startFrame), file.length)
            let framesToPlay = AVAudioFrameCount(max(0, file.length - clampedStart))
            guard framesToPlay > 0 else { continue }
            player.scheduleSegment(file, startingFrame: clampedStart, frameCount: framesToPlay, at: nil)
        }
        hasScheduledSegment = true
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
        let time = currentTime()

        if isLoopEnabled, let loopRangeSeconds, time >= loopRangeSeconds.upperBound {
            seek(toSeconds: loopRangeSeconds.lowerBound)
            return
        }

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
    }
}
