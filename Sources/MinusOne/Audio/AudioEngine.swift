import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

private let unspecifiedAudioStatus = OSStatus(-1)

final class AudioEngine {
    var onStatusChanged: ((AudioEngineStatus) -> Void)?

    /// Fires on the main queue whenever `activeOutputDevice` or `sampleRate` changes. Device
    /// switches are already handled internally (`DeviceMonitor` → `scheduleRebuildForDeviceChange`)
    /// but were previously invisible to the UI, which is why the Live tab never named the device
    /// it was actually routing through.
    var onOutputConfigurationChanged: (() -> Void)?

    private let preferences: Preferences
    private var neuralPipeline: NeuralSeparationPipeline?
    private var separationModel: AudioSeparationModel?
    private let maxFramesPerCallback = 8_192

    private var processTapSetup: TapAggregateSetup?
    private var processTapProcID: AudioDeviceIOProcID?
    private let processTapQueue = DispatchQueue(label: "com.minusone.process-tap-io", qos: .userInteractive)
    private var processTapCallbackCount: UInt64 = 0
    private var processTapLoggedFirstBuffer = false
    private var processTapLoggedNilOutput = false
    private(set) var activeCaptureBackend: CaptureBackend?
    private let processedLeft: UnsafeMutablePointer<Float>
    private let processedRight: UnsafeMutablePointer<Float>

    private(set) var status: AudioEngineStatus = .idle {
        didSet {
            guard oldValue != status else { return }
            // Every mutation site runs on the main thread already; dispatching async
            // unconditionally used to leave a one-runloop-tick window where `isVocalReductionActive`
            // (and other synchronously-updated engine state) had already changed but every UI
            // surface listening for `onStatusChanged` — menu bar icon, popover toggle, Live tab
            // header/caption — hadn't been told yet, so they'd briefly contradict each other right
            // after a toggle. Only hop to the main queue when actually called from elsewhere.
            if Thread.isMainThread {
                onStatusChanged?(status)
            } else {
                DispatchQueue.main.async { [status, onStatusChanged] in
                    onStatusChanged?(status)
                }
            }
        }
    }

    private(set) var isRunning = false
    private(set) var isReductionEnabled = false
    private(set) var activeOutputDevice: AudioDevice? {
        didSet {
            guard oldValue != activeOutputDevice else { return }
            notifyOutputConfigurationChanged()
        }
    }
    private var previousDefaultOutputID: AudioDeviceID?
    private(set) var sampleRate: Double = 48_000 {
        didSet {
            guard oldValue != sampleRate else { return }
            notifyOutputConfigurationChanged()
        }
    }
    private var suppressDeviceRebuild = false
    private var pendingDeviceRebuild: DispatchWorkItem?
    private var separationModelLoadTask: DispatchWorkItem?
    private var captureRebuildWorkItem: DispatchWorkItem?
    private let separationModelLock = NSLock()

    /// Live's per-stem fader/mute state — seeded from `Preferences` at launch, and the single
    /// source of truth `neuralPipeline?.mixDSP.stemLevels` gets pushed from on every change.
    private let stemMixer: StemMixerController

    var isNeuralSeparationAvailable: Bool {
        SeparationModelVariant.allCases.contains { SeparationModelFactory.isAvailable($0) }
    }

    var isVocalReductionActive: Bool {
        isReductionEnabled
    }

    /// Seconds left in the current warm-up, or `nil` when no pipeline is warming up.
    var warmupRemainingSeconds: Double? {
        neuralPipeline?.remainingWarmupSeconds
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        stemMixer = preferences.liveStemMixerSnapshot()
        processedLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        processedRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        processedLeft.initialize(repeating: 0, count: maxFramesPerCallback)
        processedRight.initialize(repeating: 0, count: maxFramesPerCallback)
    }

    deinit {
        stop(restoreOutput: true)
        processedLeft.deinitialize(count: maxFramesPerCallback)
        processedRight.deinitialize(count: maxFramesPerCallback)
        processedLeft.deallocate()
        processedRight.deallocate()
    }

    /// `Process Tap` requires macOS 14.2, which is the app's own minimum system version (enforced
    /// by `LSMinimumSystemVersion` in Info.plist) — the `#available` check only exists because
    /// `Package.swift`'s deployment target can't express a point release, so the compiler still
    /// requires it even though the `else` branch can never actually run on a launched copy of this
    /// app.
    func start(completion: ((Bool) -> Void)? = nil) {
        guard !isRunning else {
            completion?(true)
            return
        }

        if #available(macOS 14.2, *) {
            do {
                try startProcessTap()
                completion?(true)
            } catch let error as AudioEngineError where error.isLikelyPermissionDenied {
                // The one failure mode worth a dedicated status (and a one-click "Open Settings…"
                // button, via `updatePermissionButton`) rather than a plain error: the user denied
                // the System Audio Recording prompt.
                status = .permissionRequired(.systemAudioRecording)
                AppLogger.shared.warning("Process tap permission denied: \(error.localizedDescription)")
                completion?(false)
            } catch {
                status = .error(error.localizedDescription)
                AppLogger.shared.error("Process tap failed: \(error.localizedDescription)")
                completion?(false)
            }
        } else {
            status = .error("MinusOne requires macOS 14.2 or later.")
            completion?(false)
        }
    }

    private func startProcessTap() throws {
        if #available(macOS 14.2, *) {
            try performInternalAudioChange {
                let output = try resolveOutputDevice()
                activeOutputDevice = output

                let aggregateOutputUID: String
                if let systemOutputID = CoreAudioDevices.defaultSystemOutputDeviceID(),
                   let systemOutput = CoreAudioDevices.device(for: systemOutputID),
                   systemOutput.isOutputCapable,
                   !systemOutput.isBlackHole {
                    aggregateOutputUID = systemOutput.uid
                } else {
                    aggregateOutputUID = output.uid
                }

                let setup = try ProcessTapSession.create(
                    outputDeviceUID: aggregateOutputUID,
                    captureScope: preferences.captureScope,
                    selectedBundleIDs: preferences.selectedAppBundleIDs
                )
                processTapSetup = setup
                sampleRate = setup.sampleRate

                if let currentDefaultID = CoreAudioDevices.defaultOutputDeviceID(),
                   let currentDefaultDevice = CoreAudioDevices.device(for: currentDefaultID),
                   !currentDefaultDevice.isBlackHole,
                   !currentDefaultDevice.uid.hasPrefix("com.minusone.aggregate.") {
                    previousDefaultOutputID = currentDefaultID
                }

                try CoreAudioDevices.setDefaultOutputDevice(setup.aggregateID)
                AppLogger.shared.info(
                    "Switched default output to tap aggregate \(setup.aggregateID) (was \(previousDefaultOutputID.map(String.init) ?? "unknown"))"
                )

                processTapCallbackCount = 0
                processTapLoggedFirstBuffer = false
                processTapLoggedNilOutput = false

                let engine = self
                processTapProcID = try ProcessTapSession.startIO(
                    setup: setup,
                    queue: processTapQueue
                ) { _, inInputData, _, outOutputData, _ in
                    engine.handleProcessTapIO(
                        inInputData: inInputData,
                        outOutputData: outOutputData
                    )
                }

                isRunning = true
                isReductionEnabled = false
                activeCaptureBackend = .processTap
                let channelCount = Int(setup.streamFormat.mChannelsPerFrame)
                status = resolvedStartupStatus(channelCount: channelCount)
                AppLogger.shared.info(
                    "Audio engine started with Process Tap IO on aggregate \(setup.aggregateID) and \(output.name) output"
                )
            }
        }
    }

    private func processInPlaceAudio(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0, frameCount <= maxFramesPerCallback else { return }

        if let neuralPipeline {
            neuralPipeline.process(
                inputLeft: left,
                inputRight: right,
                outputLeft: left,
                outputRight: right,
                frameCount: frameCount
            )
        }
    }

    func stop(restoreOutput: Bool) {
        pendingDeviceRebuild?.cancel()
        pendingDeviceRebuild = nil
        stopNeuralPipeline()
        performInternalAudioChange {
            stopProcessTap()

            if restoreOutput {
                restorePreviousOutput()
            }

            isRunning = false
            isReductionEnabled = false
            activeCaptureBackend = nil
            status = .idle
        }
    }

    private func stopProcessTap() {
        if #available(macOS 14.2, *) {
            if let setup = processTapSetup {
                ProcessTapSession.stopIO(setup: setup, procID: processTapProcID)
            }
            processTapProcID = nil
            ProcessTapSession.destroy(processTapSetup)
        }
        processTapSetup = nil
        processTapCallbackCount = 0
        processTapLoggedFirstBuffer = false
        processTapLoggedNilOutput = false
    }

    private func handleProcessTapIO(
        inInputData: UnsafePointer<AudioBufferList>?,
        outOutputData: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let inInputData, let audioFormat = processTapSetup?.audioFormat else { return }
        guard let outOutputData else {
            if !processTapLoggedNilOutput {
                processTapLoggedNilOutput = true
                AppLogger.shared.error("Process tap IO proc received nil outOutputData — cannot play audio")
            }
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            bufferListNoCopy: UnsafeMutablePointer(mutating: inInputData),
            deallocator: nil
        ) else {
            return
        }

        let frameCount = TapBufferReader.frameCount(for: inputBuffer, format: audioFormat)
        guard frameCount > 0, frameCount <= maxFramesPerCallback else { return }
        guard TapBufferReader.extractStereoFloat(
            from: inputBuffer,
            format: audioFormat,
            left: processedLeft,
            right: processedRight,
            frameCount: frameCount
        ) else {
            return
        }

        processInPlaceAudio(
            left: processedLeft,
            right: processedRight,
            frameCount: frameCount
        )

        writeInterleavedStereo(
            to: outOutputData,
            left: processedLeft,
            right: processedRight,
            frameCount: frameCount
        )

        processTapCallbackCount += 1
        if !processTapLoggedFirstBuffer {
            processTapLoggedFirstBuffer = true
            let peak = peakStereoMagnitude(left: processedLeft, right: processedRight, frameCount: frameCount)
            let layout = describeOutputBufferList(outOutputData)
            AppLogger.shared.info(
                "Process tap IO: frames=\(frameCount) peak=\(String(format: "%.4f", peak)) output=\(layout)"
            )
        } else if processTapCallbackCount % 120 == 0 {
            let peak = peakStereoMagnitude(left: processedLeft, right: processedRight, frameCount: frameCount)
            AppLogger.shared.info(
                "Process tap IO heartbeat: callbacks=\(processTapCallbackCount) peak=\(String(format: "%.4f", peak))"
            )
        }
    }

    private func writeInterleavedStereo(
        to output: UnsafeMutablePointer<AudioBufferList>,
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let data = buffers.first?.mData else { return }

        let byteCount = frameCount * 2 * MemoryLayout<Float>.size
        let interleaved = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frameCount {
            interleaved[frame * 2] = left[frame]
            interleaved[frame * 2 + 1] = right[frame]
        }
        buffers[0].mDataByteSize = UInt32(byteCount)
    }

    private func describeOutputBufferList(_ output: UnsafeMutablePointer<AudioBufferList>) -> String {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let parts = (0..<buffers.count).map { index in
            "b\(index):ch=\(buffers[index].mNumberChannels),bytes=\(buffers[index].mDataByteSize)"
        }
        return parts.joined(separator: " ")
    }

    private func peakStereoMagnitude(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) -> Float {
        var peak: Float = 0
        for frame in 0..<frameCount {
            peak = max(peak, abs(left[frame]), abs(right[frame]))
        }
        return peak
    }

    func toggleReduction() {
        if isRunning && isReductionEnabled {
            disableReduction()
            return
        }

        if !isRunning {
            start { [weak self] success in
                guard let self, success else { return }
                self.enableReduction()
            }
            return
        }

        enableReduction()
    }

    func enableReduction() {
        guard isRunning else { return }

        isReductionEnabled = true
        if neuralPipeline == nil {
            startNeuralPipelineIfNeeded()
        }
        neuralPipeline?.mixDSP.masterEnabled.store(1)
        applyStemMixSnapshot()
        updateActiveStatus()
        AppLogger.shared.info("Vocal reduction enabled")
    }

    func disableReduction() {
        guard isRunning else { return }

        isReductionEnabled = false
        // Bypass only — never touch the user's stem mix, so it's exactly as they left it next time.
        neuralPipeline?.mixDSP.masterEnabled.store(0)
        updateActiveStatus()
        AppLogger.shared.info("Vocal reduction disabled — passthrough")
    }

    /// Pushes the mixer's current `effectiveVolume(for:)` for every stem into the live pipeline,
    /// plus makeup gain (which tracks how much vocal is actually being removed). The one place all
    /// 3 per-stem setters below, `enableReduction()`, and device-rebuild funnel through, so the
    /// pipeline never sees a partial update.
    private func applyStemMixSnapshot() {
        guard let mixDSP = neuralPipeline?.mixDSP else { return }
        for stem in SeparationStem.allCases {
            mixDSP.stemLevels[stem]?.store(stemMixer.effectiveVolume(for: stem))
        }
        applyMakeupGain()
    }

    private func applyMakeupGain() {
        neuralPipeline?.mixDSP.makeupGainDecibels.store(preferences.makeupGainDecibels)
    }

    func setStemVolume(_ volume: Float, for stem: SeparationStem) {
        stemMixer.setVolume(volume, for: stem)
        preferences.persistLiveStemMixer(stemMixer)
        guard isReductionEnabled else { return }
        applyStemMixSnapshot()
    }

    func setStemMuted(_ muted: Bool, for stem: SeparationStem) {
        stemMixer.setMuted(muted, for: stem)
        preferences.persistLiveStemMixer(stemMixer)
        guard isReductionEnabled else { return }
        applyStemMixSnapshot()
    }

    func isolateStem(_ stem: SeparationStem) {
        stemMixer.isolateStem(stem)
        preferences.persistLiveStemMixer(stemMixer)
        guard isReductionEnabled else { return }
        applyStemMixSnapshot()
    }

    /// Latest aligned dry/wet peak pair from the mix stage, or `nil` when no pipeline is running.
    /// Callers poll this at their own cadence — deliberately no timer here, so nothing ticks while
    /// the window is closed. `nil` (rather than a zeroed pair) lets the meter decay to silence
    /// instead of snapping to a flat line.
    var liveLevels: (dry: Float, wet: Float)? {
        guard let mixDSP = neuralPipeline?.mixDSP else { return nil }
        return (mixDSP.dryPeak.load(), mixDSP.wetPeak.load())
    }

    /// Each stem's raw (pre-fader) peak this callback, or `nil` when no pipeline is running — feeds
    /// the Live tab meter's Practice-style per-stem color blend.
    var liveStemLevels: [SeparationStem: Float]? {
        guard let mixDSP = neuralPipeline?.mixDSP else { return nil }
        return Dictionary(uniqueKeysWithValues: SeparationStem.allCases.map { ($0, mixDSP.stemPeaks[$0]?.load() ?? 0) })
    }

    private func notifyOutputConfigurationChanged() {
        DispatchQueue.main.async { [onOutputConfigurationChanged] in
            onOutputConfigurationChanged?()
        }
    }

    private func updateActiveStatus() {
        guard isReductionEnabled else {
            status = isRunning ? .passthrough : .idle
            return
        }

        if let pipeline = neuralPipeline {
            switch pipeline.state {
            case .warmingUp, .idle:
                status = .warmingUp
            case .ready:
                status = .active
            case .error(let message):
                status = .error(message)
            }
            return
        }

        // Model or pipeline still starting — don't flash active before warm-up.
        status = .warmingUp
    }

    func preloadSeparationModelIfNeeded() {
        guard SeparationModelFactory.isAvailable(preferences.separationModelVariant) else { return }

        separationModelLock.lock()
        if separationModel != nil {
            separationModelLock.unlock()
            return
        }
        if separationModelLoadTask != nil {
            separationModelLock.unlock()
            return
        }

        let variant = preferences.separationModelVariant
        let rate = sampleRate
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let model = try SeparationModelFactory.loadModel(
                    variant: variant,
                    captureSampleRate: rate
                )
                self.separationModelLock.lock()
                if self.separationModel == nil {
                    self.separationModel = model
                }
                self.separationModelLoadTask = nil
                self.separationModelLock.unlock()

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, self.isReductionEnabled else { return }
                    if self.neuralPipeline == nil {
                        self.startNeuralPipelineIfNeeded()
                        // `enableReduction()` already tried this once, but `neuralPipeline` was
                        // still nil at that point (the model hadn't loaded yet) — both calls
                        // silently no-op through `neuralPipeline?...`. This is the first moment a
                        // real pipeline exists, so it's the first moment this can actually land;
                        // without it, the pipeline's mixer sits at its constructor defaults
                        // (`masterEnabled` 0, every stem level 0) forever — it warms up and reaches
                        // "ready," but never actually mixes, until something else happens to call
                        // `enableReduction()` again with a non-nil pipeline (e.g. toggling off/on).
                        self.neuralPipeline?.mixDSP.masterEnabled.store(1)
                        self.applyStemMixSnapshot()
                        self.updateActiveStatus()
                    }
                }
            } catch {
                self.separationModelLock.lock()
                self.separationModelLoadTask = nil
                self.separationModelLock.unlock()
                AppLogger.shared.error("Background separation model preload failed: \(error.localizedDescription)")
            }
        }
        separationModelLoadTask = task
        separationModelLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    private func startNeuralPipelineIfNeeded() {
        stopNeuralPipeline()
        guard isReductionEnabled else { return }

        separationModelLock.lock()
        let model = separationModel
        separationModelLock.unlock()
        guard let model else {
            preloadSeparationModelIfNeeded()
            status = .warmingUp
            return
        }

        let windowSeconds = model.preferredWindowSeconds
        // Larger hop = fewer full-window Demucs passes (~3.5 s vs former 2 s).
        let hopSeconds = min(3.5, max(2.5, windowSeconds / 3))

        let pipeline = NeuralSeparationPipeline(
            model: model,
            sampleRate: sampleRate,
            windowSeconds: windowSeconds,
            hopSeconds: hopSeconds,
            makeupGainDecibels: preferences.makeupGainDecibels,
            rampDurationMilliseconds: preferences.rampDurationMilliseconds,
            maxFramesPerCallback: maxFramesPerCallback
        )
        neuralPipeline = pipeline
        pipeline.setStateChangeHandler { [weak self] state in
            guard let self, self.isRunning else { return }
            switch state {
            case .warmingUp:
                if case .error = self.status { return }
                self.status = .warmingUp
            case .ready:
                self.updateActiveStatus()
            case .error(let message):
                self.status = .error(message)
            case .idle:
                break
            }
        }
        pipeline.start()
        AppLogger.shared.info(
            "Neural separation active (~\(String(format: "%.1f", pipeline.playbackDelaySeconds)) s playback delay)"
        )
    }

    private func stopNeuralPipeline() {
        neuralPipeline?.stop()
        neuralPipeline = nil
    }

    private func resolvedStartupStatus(channelCount: Int) -> AudioEngineStatus {
        // Reduction is always off at engine start — neural warm-up begins on enableReduction.
        return .passthrough
    }

    func setMakeupGainDecibels(_ value: Float) {
        preferences.makeupGainDecibels = value
        neuralPipeline?.mixDSP.makeupGainDecibels.store(value)
    }

    func setCaptureScope(_ scope: CaptureScope) {
        guard preferences.captureScope != scope else { return }
        preferences.captureScope = scope
        rebuildForCaptureConfigChangeIfNeeded()
    }

    func setSelectedAppBundleIDs(_ bundleIDs: Set<String>) {
        guard preferences.selectedAppBundleIDs != bundleIDs else { return }
        preferences.selectedAppBundleIDs = bundleIDs
        rebuildForCaptureConfigChangeIfNeeded()
    }

    func toggleSelectedAppBundleID(_ bundleID: String) {
        var selected = preferences.selectedAppBundleIDs
        if selected.contains(bundleID) {
            selected.remove(bundleID)
        } else {
            selected.insert(bundleID)
        }
        setSelectedAppBundleIDs(selected)
    }

    private func rebuildForCaptureConfigChangeIfNeeded() {
        guard isRunning, activeCaptureBackend == .processTap else { return }
        guard captureConfigurationIsValidForProcessTap() else { return }

        captureRebuildWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.scheduleRebuildForDeviceChange()
        }
        captureRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func captureConfigurationIsValidForProcessTap() -> Bool {
        guard preferences.captureScope == .selectedApps else { return true }
        guard !preferences.selectedAppBundleIDs.isEmpty else { return false }
        if #available(macOS 14.2, *) {
            return !AudioProcessEnumerator.processObjectIDs(
                forBundleIDs: preferences.selectedAppBundleIDs
            ).isEmpty
        }
        return false
    }

    func scheduleRebuildForDeviceChange() {
        pendingDeviceRebuild?.cancel()

        let wasReducing = isReductionEnabled
        if wasReducing {
            neuralPipeline?.mixDSP.masterEnabled.store(0)
        }

        let fadeSeconds = wasReducing
            ? Double(preferences.rampDurationMilliseconds) / 1000.0 + 0.05
            : 0

        let item = DispatchWorkItem { [weak self] in
            self?.rebuildForDeviceChange()
        }
        pendingDeviceRebuild = item
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeSeconds, execute: item)
    }

    func rebuildForDeviceChange() {
        guard isRunning, !suppressDeviceRebuild else { return }

        if activeCaptureBackend == .processTap,
           let defaultID = CoreAudioDevices.defaultOutputDeviceID(),
           let defaultDevice = CoreAudioDevices.device(for: defaultID),
           defaultDevice.uid.hasPrefix("com.minusone.aggregate.") {
            return
        }

        guard let resolved = try? resolveOutputDevice() else { return }
        if let active = activeOutputDevice, resolved.uid == active.uid {
            return
        }

        let shouldRestoreReduction = isReductionEnabled
        performInternalAudioChange {
            stopProcessTap()

            do {
                guard #available(macOS 14.2, *) else {
                    throw AudioEngineError.coreAudio("MinusOne requires macOS 14.2 or later", unspecifiedAudioStatus)
                }
                try startProcessTap()
                isReductionEnabled = shouldRestoreReduction
                if shouldRestoreReduction {
                    startNeuralPipelineIfNeeded()
                }
                if isReductionEnabled {
                    neuralPipeline?.mixDSP.masterEnabled.store(1)
                    applyStemMixSnapshot()
                } else {
                    neuralPipeline?.mixDSP.masterEnabled.store(0)
                }
                if let output = activeOutputDevice {
                    AppLogger.shared.info("Audio engine rebuilt for output device \(output.name)")
                }
                updateActiveStatus()
            } catch {
                status = .error(error.localizedDescription)
                AppLogger.shared.error("Audio engine rebuild failed: \(error.localizedDescription)")
                stop(restoreOutput: true)
            }
        }
    }

    private func performInternalAudioChange(_ work: () throws -> Void) rethrows {
        suppressDeviceRebuild = true
        defer { suppressDeviceRebuild = false }
        try work()
    }

    private func performInternalAudioChange(_ work: () -> Void) {
        suppressDeviceRebuild = true
        defer { suppressDeviceRebuild = false }
        work()
    }

    private func resolveOutputDevice() throws -> AudioDevice {
        if let systemOutputID = CoreAudioDevices.defaultSystemOutputDeviceID(),
           let systemOutput = CoreAudioDevices.device(for: systemOutputID),
           systemOutput.isOutputCapable,
           !systemOutput.isBlackHole {
            return systemOutput
        }

        if let defaultID = CoreAudioDevices.defaultOutputDeviceID(),
           let defaultDevice = CoreAudioDevices.device(for: defaultID),
           defaultDevice.isOutputCapable,
           !defaultDevice.isBlackHole,
           !defaultDevice.uid.hasPrefix("com.minusone.aggregate.") {
            return defaultDevice
        }

        guard let first = CoreAudioDevices.outputDevices().first else {
            throw AudioEngineError.noPhysicalOutput
        }
        return first
    }

    private func restorePreviousOutput() {
        guard let previousDefaultOutputID else { return }

        do {
            try CoreAudioDevices.setDefaultOutputDevice(previousDefaultOutputID)
            AppLogger.shared.info("Restored default output to device \(previousDefaultOutputID)")
            self.previousDefaultOutputID = nil
        } catch {
            AppLogger.shared.error("Failed to restore previous output: \(error.localizedDescription)")
        }
    }

}
