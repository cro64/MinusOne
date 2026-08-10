import AVFoundation
import CoreAudio

/// Records system audio straight to a file via an independent, passive (`.unmuted`) Process Tap —
/// separate from Live Mode's own tap, safe to run alongside it since neither touches the other's
/// state and this one never changes the default output device.
@available(macOS 14.2, *)
final class SystemAudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case unavailable
        case noOutputDevice
        case notRecording

        var errorDescription: String? {
            switch self {
            case .unavailable: return "System audio recording requires macOS 14.2 or later."
            case .noOutputDevice: return "No audio output device is available to record from."
            case .notRecording: return "Not currently recording."
            }
        }
    }

    /// Fires on the peaks/elapsed update cadence (~10Hz) — call on main thread already.
    var onProgress: ((_ peaks: [Float], _ elapsedSeconds: Double) -> Void)?

    private(set) var isRecording = false

    private let ioQueue = DispatchQueue(label: "com.minusone.app.practice-record", qos: .userInitiated)
    private let stateLock = NSLock()

    private var setup: TapAggregateSetup?
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var scratchBuffer: AVAudioPCMBuffer?
    private var scratchLeft: [Float] = []
    private var scratchRight: [Float] = []
    private static let maxFramesPerCallback = 16_384

    private var recordingURL: URL?
    private var sampleRate: Double = 44_100
    private var framesWritten: Int64 = 0

    private var peaks: [Float] = []
    private var bucketSampleCount = 1
    private var samplesInBucket = 0
    private var bucketMin: Float = 0
    private var bucketMax: Float = 0

    private var autoStopTimer: Timer?
    private var progressTimer: Timer?
    private var loggedFirstWriteError = false

    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRecording else { return }

        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.setupAndStart()
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.startProgressTimer()
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Returns the recorded file's URL, or nil if nothing was captured.
    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil

        if let setup {
            ProcessTapSession.stopIO(setup: setup, procID: procID)
            ProcessTapSession.destroy(setup)
        }
        procID = nil
        self.setup = nil

        let url = recordingURL
        let finalFrames = framesWritten
        file = nil
        fileFormat = nil
        scratchBuffer = nil
        recordingURL = nil
        AppLogger.shared.info("Practice recording stopped: \(url?.lastPathComponent ?? "nil"), framesWritten=\(finalFrames)")
        return url
    }

    /// Reschedules (or cancels, if `seconds` is nil) the auto-stop timer — callable any time while recording.
    func setAutoStop(seconds: Double?, onFire: @escaping () -> Void) {
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        guard isRecording, let seconds, seconds > 0 else { return }

        let remaining = max(0, seconds - elapsedSeconds())
        let timer = Timer(timeInterval: remaining, repeats: false) { _ in
            onFire()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoStopTimer = timer
    }

    func elapsedSeconds() -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Double(framesWritten) / sampleRate
    }

    // MARK: - Setup (runs on ioQueue)

    private func setupAndStart() throws {
        guard let defaultID = CoreAudioDevices.defaultOutputDeviceID(),
              let device = CoreAudioDevices.device(for: defaultID)
        else {
            throw RecorderError.noOutputDevice
        }

        let newSetup = try ProcessTapSession.create(
            outputDeviceUID: device.uid,
            captureScope: .allApps,
            selectedBundleIDs: [],
            muteBehavior: .unmuted
        )

        // PCM files on disk are always interleaved, but AVAudioFile's own `processingFormat` —
        // what `write(from:)` actually requires the buffer to match — is non-interleaved Float32
        // regardless of what `settings` says. Build the file from interleaved settings, but the
        // scratch buffer from the file's real processing format (same lesson as OfflineSeparationEngine).
        let interleavedSettingsFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: newSetup.sampleRate,
            channels: 2,
            interleaved: true
        )!
        let url = Self.makeRecordingURL()
        let audioFile = try AVAudioFile(forWriting: url, settings: interleavedSettingsFormat.settings)
        let writeFormat = audioFile.processingFormat
        guard let scratch = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: AVAudioFrameCount(Self.maxFramesPerCallback)) else {
            throw RecorderError.noOutputDevice
        }

        setup = newSetup
        fileFormat = writeFormat
        file = audioFile
        scratchBuffer = scratch
        scratchLeft = [Float](repeating: 0, count: Self.maxFramesPerCallback)
        scratchRight = [Float](repeating: 0, count: Self.maxFramesPerCallback)
        recordingURL = url
        sampleRate = newSetup.sampleRate
        bucketSampleCount = max(1, Int(newSetup.sampleRate * 0.1))
        samplesInBucket = 0
        bucketMin = 0
        bucketMax = 0
        framesWritten = 0
        peaks = []
        loggedFirstWriteError = false

        let recorder = self
        procID = try ProcessTapSession.startIO(setup: newSetup, queue: ioQueue) { _, inInputData, _, _, _ in
            recorder.handleIO(inInputData: inInputData)
        }
        AppLogger.shared.info("Practice recording started: \(url.lastPathComponent), writeFormat=\(writeFormat)")
    }

    // MARK: - IO (runs on ioQueue, called by CoreAudio)

    private func handleIO(inInputData: UnsafePointer<AudioBufferList>?) {
        guard let inInputData, let tapFormat = setup?.audioFormat, let file, let scratch = scratchBuffer else { return }
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: UnsafeMutablePointer(mutating: inInputData),
            deallocator: nil
        ) else { return }

        let frameCount = Self.frameCount(for: inputBuffer, format: tapFormat)
        guard frameCount > 0, frameCount <= Self.maxFramesPerCallback else { return }

        let extracted = scratchLeft.withUnsafeMutableBufferPointer { left -> Bool in
            scratchRight.withUnsafeMutableBufferPointer { right in
                Self.extractStereoFloat(
                    from: inputBuffer,
                    format: tapFormat,
                    left: left.baseAddress!,
                    right: right.baseAddress!,
                    frameCount: frameCount
                )
            }
        }
        guard extracted else { return }

        scratch.frameLength = AVAudioFrameCount(frameCount)
        guard let scratchChannels = scratch.floatChannelData else { return }
        scratchLeft.withUnsafeBufferPointer { left in
            scratchChannels[0].update(from: left.baseAddress!, count: frameCount)
        }
        scratchRight.withUnsafeBufferPointer { right in
            scratchChannels[1].update(from: right.baseAddress!, count: frameCount)
        }

        do {
            try file.write(from: scratch)
        } catch {
            if !loggedFirstWriteError {
                loggedFirstWriteError = true
                AppLogger.shared.error("Practice recording write failed: \(error.localizedDescription)")
            }
            return
        }

        accumulatePeaks(frameCount: frameCount)

        stateLock.lock()
        framesWritten += Int64(frameCount)
        stateLock.unlock()
    }

    private func accumulatePeaks(frameCount: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        for frame in 0..<frameCount {
            let sample = (scratchLeft[frame] + scratchRight[frame]) * 0.5
            if sample < bucketMin { bucketMin = sample }
            if sample > bucketMax { bucketMax = sample }
            samplesInBucket += 1
            if samplesInBucket >= bucketSampleCount {
                peaks.append(bucketMin)
                peaks.append(bucketMax)
                bucketMin = 0
                bucketMax = 0
                samplesInBucket = 0
            }
        }
    }

    // MARK: - Progress polling (main thread)

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let currentPeaks = self.peaks
            self.stateLock.unlock()
            self.onProgress?(currentPeaks, self.elapsedSeconds())
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    // MARK: - Helpers

    private static func makeRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Recording \(formatter.string(from: Date())).caf"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private static func frameCount(for buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> Int {
        if buffer.frameLength > 0 {
            return Int(buffer.frameLength)
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return 0 }
        let channels = max(Int(format.channelCount), 1)
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }

    /// Same technique as `AudioEngine.extractStereoFloat` — handles both interleaved and planar tap formats.
    private static func extractStereoFloat(
        from buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        if format.isInterleaved {
            guard let data = buffer.audioBufferList.pointee.mBuffers.mData else { return false }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                left[frame] = samples[frame * 2]
                right[frame] = samples[frame * 2 + 1]
            }
            return true
        }

        guard let channels = buffer.floatChannelData else { return false }
        if format.channelCount >= 2 {
            left.update(from: channels[0], count: frameCount)
            right.update(from: channels[1], count: frameCount)
            return true
        }

        left.update(from: channels[0], count: frameCount)
        for frame in 0..<frameCount {
            right[frame] = channels[0][frame]
        }
        return true
    }
}
