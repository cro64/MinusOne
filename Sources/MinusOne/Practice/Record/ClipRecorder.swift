import AVFoundation
import CoreAudio

/// Records a Practice take straight to a file, from either of two sources:
///
/// - **System audio** — an independent, passive (`.unmuted`) Process Tap, separate from Live Mode's
///   own tap and safe to run alongside it, since neither touches the other's state and this one
///   never changes the default output device.
/// - **An input device** — a plain CoreAudio IOProc on the device itself, for recording a mic or
///   interface rather than what the machine is playing.
///
/// Everything downstream of the source is shared: both paths hand the same `AudioBufferList` to
/// `handleIO`, which extracts stereo float, writes to the same `AVAudioFile`, and accumulates the
/// same 0.1s peak buckets. Only acquisition and teardown differ, which is what `ActiveSource` holds.
@available(macOS 14.2, *)
final class ClipRecorder {
    enum RecorderError: Error, LocalizedError {
        case unavailable
        case noOutputDevice
        case notRecording
        case inputDeviceUnavailable
        case inputFormatUnavailable(name: String)
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
            case .unavailable: return "System audio recording requires macOS 14.2 or later."
            case .noOutputDevice: return "No audio output device is available to record from."
            case .notRecording: return "Not currently recording."
            case .inputDeviceUnavailable:
                // Deliberately unnamed: this case fires precisely because the device could not be
                // found, so any name here is a placeholder describing itself ("Unavailable device
                // isn't available").
                return "The selected input device isn't available. It may have been unplugged."
            case .inputFormatUnavailable(let name):
                return "Couldn't read an input format from \(name)."
            case .microphonePermissionDenied:
                return "MinusOne needs microphone access to record from an input device."
            }
        }

        /// Drives which System Settings pane the record page's button opens.
        var isMicrophonePermissionIssue: Bool {
            if case .microphonePermissionDenied = self { return true }
            return false
        }
    }

    /// How the current take is being captured. Both cases resolve to "an `AudioDeviceID` with an
    /// IOProc on it" — the tap case just has an aggregate device to tear down afterwards.
    private enum ActiveSource {
        case systemAudio(TapAggregateSetup)
        case inputDevice(id: AudioDeviceID, format: AVAudioFormat, sampleRate: Double)

        /// The device the IOProc is attached to.
        var deviceID: AudioDeviceID {
            switch self {
            case .systemAudio(let setup): return setup.aggregateID
            case .inputDevice(let id, _, _): return id
            }
        }

        /// The format of the buffers arriving in the IO callback.
        var audioFormat: AVAudioFormat {
            switch self {
            case .systemAudio(let setup): return setup.audioFormat
            case .inputDevice(_, let format, _): return format
            }
        }

        var sampleRate: Double {
            switch self {
            case .systemAudio(let setup): return setup.sampleRate
            case .inputDevice(_, _, let rate): return rate
            }
        }
    }

    /// Fires on the peaks/elapsed update cadence (~10Hz) — call on main thread already.
    var onProgress: ((_ peaks: [Float], _ elapsedSeconds: Double) -> Void)?

    /// Fires on the main thread whenever `isRecording` flips, whichever surface caused it. Several
    /// places follow recording state now (menu bar icon, the window's Practice toolbar, the record
    /// page), so they can't each poll a bool they own — `AppDelegate` holds this one closure and
    /// fans it out, the same shape as `AudioEngine.onStatusChanged`.
    var onRecordingStateChanged: ((_ isRecording: Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            onRecordingStateChanged?(isRecording)
        }
    }

    private let ioQueue = DispatchQueue(label: "com.minusone.app.practice-record", qos: .userInitiated)
    private let stateLock = NSLock()

    private var source: ActiveSource?
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

    /// Starts a take from `source`. Microphone permission is resolved on the main thread *before*
    /// any CoreAudio work, because the TCC prompt is the one part of this that must not run on the
    /// IO queue — and because a denial should read as "grant access", not as a device failure.
    func startRecording(source: RecordingSource, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRecording else { return }

        guard source.isMicrophone else {
            beginCapture(source: source, completion: completion)
            return
        }

        AudioPermission.requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(RecorderError.microphonePermissionDenied))
                return
            }
            self.beginCapture(source: source, completion: completion)
        }
    }

    private func beginCapture(source: RecordingSource, completion: @escaping (Result<Void, Error>) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.setupAndStart(source: source)
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

        if let source {
            stopIO(source: source)
            // Only the tap path leaves an aggregate device behind; an input device is the user's
            // own hardware and must be left exactly as it was found.
            if case .systemAudio(let setup) = source {
                ProcessTapSession.destroy(setup)
            }
        }
        procID = nil
        self.source = nil

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

    private func setupAndStart(source requested: RecordingSource) throws {
        let newSource = try makeSource(for: requested)

        // PCM files on disk are always interleaved, but AVAudioFile's own `processingFormat` —
        // what `write(from:)` actually requires the buffer to match — is non-interleaved Float32
        // regardless of what `settings` says. Build the file from interleaved settings, but the
        // scratch buffer from the file's real processing format (same lesson as OfflineSeparationEngine).
        let interleavedSettingsFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: newSource.sampleRate,
            channels: 2,
            interleaved: true
        )!
        let url = Self.makeRecordingURL()
        let audioFile = try AVAudioFile(forWriting: url, settings: interleavedSettingsFormat.settings)
        let writeFormat = audioFile.processingFormat
        guard let scratch = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: AVAudioFrameCount(Self.maxFramesPerCallback)) else {
            throw RecorderError.noOutputDevice
        }

        source = newSource
        fileFormat = writeFormat
        file = audioFile
        scratchBuffer = scratch
        scratchLeft = [Float](repeating: 0, count: Self.maxFramesPerCallback)
        scratchRight = [Float](repeating: 0, count: Self.maxFramesPerCallback)
        recordingURL = url
        sampleRate = newSource.sampleRate
        bucketSampleCount = max(1, Int(newSource.sampleRate * 0.1))
        samplesInBucket = 0
        bucketMin = 0
        bucketMax = 0
        framesWritten = 0
        peaks = []
        loggedFirstWriteError = false

        try startIO(source: newSource)
        AppLogger.shared.info("Practice recording started from \(requested.displayName): \(url.lastPathComponent), writeFormat=\(writeFormat)")
    }

    /// Acquires the capture device for `requested`, without touching any of the recorder's state —
    /// so a failure here leaves a previous take's teardown untouched and nothing half-configured.
    private func makeSource(for requested: RecordingSource) throws -> ActiveSource {
        switch requested {
        case .systemAudio:
            guard let defaultID = CoreAudioDevices.defaultOutputDeviceID(),
                  let device = CoreAudioDevices.device(for: defaultID)
            else {
                throw RecorderError.noOutputDevice
            }
            let setup = try ProcessTapSession.create(
                outputDeviceUID: device.uid,
                captureScope: .allApps,
                selectedBundleIDs: [],
                muteBehavior: .unmuted
            )
            return .systemAudio(setup)

        case .inputDevice(let uid):
            guard let device = CoreAudioDevices.device(withUID: uid), device.isInputCapable else {
                throw RecorderError.inputDeviceUnavailable
            }
            guard let format = Self.inputFormat(for: device.id) else {
                throw RecorderError.inputFormatUnavailable(name: device.name)
            }
            return .inputDevice(id: device.id, format: format, sampleRate: format.sampleRate)
        }
    }

    /// The device's *current* input stream format. Read rather than assumed: mics vary in rate and
    /// channel count (built-in mics are typically mono), and `handleIO` needs the real layout to
    /// interpret the buffer list — `extractStereoFloat` already duplicates a mono channel to both
    /// sides, but only if it's told the format is mono.
    private static func inputFormat(for deviceID: AudioDeviceID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &description)
        guard status == noErr else {
            AppLogger.shared.error("Unable to read input stream format for device \(deviceID): OSStatus \(status)")
            return nil
        }
        return AVAudioFormat(streamDescription: &description)
    }

    private func startIO(source: ActiveSource) throws {
        switch source {
        case .systemAudio(let setup):
            let recorder = self
            procID = try ProcessTapSession.startIO(setup: setup, queue: ioQueue) { _, inInputData, _, _, _ in
                recorder.handleIO(inInputData: inInputData)
            }

        case .inputDevice(let id, _, _):
            let recorder = self
            var newProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, id, ioQueue) { _, inInputData, _, _, _ in
                recorder.handleIO(inInputData: inInputData)
            }
            guard createStatus == noErr, let newProcID else {
                throw AudioEngineError.coreAudio("Create input device IO proc", createStatus)
            }
            let startStatus = AudioDeviceStart(id, newProcID)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(id, newProcID)
                throw AudioEngineError.coreAudio("Start input device", startStatus)
            }
            procID = newProcID
        }
    }

    /// Symmetric teardown for both source kinds. `ProcessTapSession.stopIO` does exactly this for
    /// the aggregate; the input path can't reuse it because it takes a `TapAggregateSetup`.
    private func stopIO(source: ActiveSource) {
        guard let procID else { return }
        let deviceID = source.deviceID
        let stopStatus = AudioDeviceStop(deviceID, procID)
        if stopStatus != noErr {
            AppLogger.shared.error("AudioDeviceStop failed: OSStatus \(stopStatus)")
        }
        let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, procID)
        if destroyStatus != noErr {
            AppLogger.shared.error("AudioDeviceDestroyIOProcID failed: OSStatus \(destroyStatus)")
        }
    }

    // MARK: - IO (runs on ioQueue, called by CoreAudio)

    private func handleIO(inInputData: UnsafePointer<AudioBufferList>?) {
        guard let inInputData, let tapFormat = source?.audioFormat, let file, let scratch = scratchBuffer else { return }
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: UnsafeMutablePointer(mutating: inInputData),
            deallocator: nil
        ) else { return }

        let frameCount = TapBufferReader.frameCount(for: inputBuffer, format: tapFormat)
        guard frameCount > 0, frameCount <= Self.maxFramesPerCallback else { return }

        let extracted = scratchLeft.withUnsafeMutableBufferPointer { left -> Bool in
            scratchRight.withUnsafeMutableBufferPointer { right in
                TapBufferReader.extractStereoFloat(
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
}
