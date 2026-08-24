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
    private let ringBuffer = StereoRingBuffer(capacityPowerOfTwo: 65_536)
    private let maxFramesPerCallback = 8_192

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var processTapSetup: TapAggregateSetup?
    private var processTapProcID: AudioDeviceIOProcID?
    private let processTapQueue = DispatchQueue(label: "com.minusone.process-tap-io", qos: .userInteractive)
    private var processTapCallbackCount: UInt64 = 0
    private var processTapLoggedFirstBuffer = false
    private var processTapLoggedNilOutput = false
    private(set) var activeCaptureBackend: CaptureBackend?
    private var captureBuffers: UnsafeMutableAudioBufferListPointer
    private let processedLeft: UnsafeMutablePointer<Float>
    private let processedRight: UnsafeMutablePointer<Float>

    private(set) var status: AudioEngineStatus = .idle {
        didSet {
            guard oldValue != status else { return }
            DispatchQueue.main.async { [status, onStatusChanged] in
                onStatusChanged?(status)
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
    private var lastProcessTapPermissionDenied = false
    private var separationModelLoadTask: DispatchWorkItem?
    private var captureRebuildWorkItem: DispatchWorkItem?
    private let separationModelLock = NSLock()

    var isNeuralSeparationAvailable: Bool {
        SeparationModelVariant.allCases.contains { SeparationModelFactory.isAvailable($0) }
    }

    var isVocalReductionActive: Bool {
        isReductionEnabled
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        captureBuffers = AudioBufferList.allocate(maximumBuffers: 2)
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
        captureBuffers.unsafeMutablePointer.deallocate()
    }

    func recoverOrphanedBlackHoleIfNeeded() {
        CoreAudioDevices.logDeviceSnapshot(reason: "launch")

        guard
            let defaultID = CoreAudioDevices.defaultOutputDeviceID(),
            let defaultDevice = CoreAudioDevices.device(for: defaultID),
            defaultDevice.isBlackHole,
            let fallback = CoreAudioDevices.outputDevices().first
        else {
            return
        }

        do {
            try CoreAudioDevices.setDefaultOutputDevice(fallback.id)
            AppLogger.shared.info("Recovered orphaned BlackHole default output by switching to \(fallback.name)")
        } catch {
            AppLogger.shared.error("Failed to recover orphaned BlackHole output: \(error.localizedDescription)")
        }
    }

    func start(completion: ((Bool) -> Void)? = nil) {
        guard !isRunning else {
            completion?(true)
            return
        }

        if #available(macOS 14.2, *) {
            do {
                try startProcessTap()
                completion?(true)
                return
            } catch AudioEngineError.noSelectedAudioProcesses {
                let message = AudioEngineError.noSelectedAudioProcesses.localizedDescription
                status = .error(message)
                AppLogger.shared.error("Process tap failed: \(message)")
                completion?(false)
                return
            } catch let error as AudioEngineError where error.isLikelyPermissionDenied {
                lastProcessTapPermissionDenied = true
                AppLogger.shared.warning(
                    "Process tap permission denied, falling back to BlackHole: \(error.localizedDescription)"
                )
            } catch {
                AppLogger.shared.warning(
                    "Process tap failed, falling back to BlackHole: \(error.localizedDescription)"
                )
            }
        }

        startBlackHoleWithPermission(completion: completion)
    }

    private func startBlackHoleWithPermission(completion: ((Bool) -> Void)? = nil) {
        guard !AudioPermission.isMicrophoneDenied else {
            status = .permissionRequired(.microphone)
            completion?(false)
            return
        }

        AudioPermission.requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.status = .permissionRequired(.microphone)
                completion?(false)
                return
            }

            do {
                try self.startBlackHole()
                completion?(true)
            } catch {
                if self.lastProcessTapPermissionDenied,
                   case AudioEngineError.blackHoleMissing = error {
                    self.status = .permissionRequired(.systemAudioRecording)
                } else {
                    self.status = .error(error.localizedDescription)
                }
                AppLogger.shared.error("Audio engine failed to start: \(error.localizedDescription)")
                self.stopAudioUnitsOnly()
                self.stopProcessTap()
                self.restorePreviousOutput()
                completion?(false)
            }
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

                ringBuffer.reset()
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

    private func startBlackHole() throws {
        try performInternalAudioChange {
        let blackHole = try requireBlackHole()
        let output = try resolveOutputDevice()
        activeOutputDevice = output
        sampleRate = nominalSampleRate(for: output.id) ?? 48_000

        if let currentDefaultID = CoreAudioDevices.defaultOutputDeviceID(),
           let currentDefaultDevice = CoreAudioDevices.device(for: currentDefaultID),
           !currentDefaultDevice.isBlackHole {
            previousDefaultOutputID = currentDefaultID
        }

        try CoreAudioDevices.setDefaultOutputDevice(blackHole.id)
        try configureAudioUnits(inputDevice: blackHole, outputDevice: output)

        ringBuffer.reset()

        try startUnit(inputUnit, label: "input")
        try startUnit(outputUnit, label: "output")

        isRunning = true
        isReductionEnabled = false
        activeCaptureBackend = .blackHole
        status = resolvedStartupStatus(channelCount: Int(blackHole.inputChannelCount))
        AppLogger.shared.info("Audio engine started with BlackHole input and \(output.name) output")
        }
    }

    private func ingestCapturedAudio(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0, frameCount <= maxFramesPerCallback else { return }

        if let neuralPipeline {
            neuralPipeline.process(
                inputLeft: left,
                inputRight: right,
                outputLeft: processedLeft,
                outputRight: processedRight,
                frameCount: frameCount
            )
        } else {
            processedLeft.update(from: left, count: frameCount)
            processedRight.update(from: right, count: frameCount)
        }

        ringBuffer.write(left: processedLeft, right: processedRight, frameCount: frameCount)
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
            stopAudioUnitsOnly()
            stopProcessTap()

            if restoreOutput {
                restorePreviousOutput()
            }

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
        preferences.lastReductionEnabled = true
        if neuralPipeline == nil {
            startNeuralPipelineIfNeeded()
        }
        applyReductionIntensity(preferences.targetIntensity)
        updateActiveStatus()
        AppLogger.shared.info("Vocal reduction enabled (target intensity \(preferences.targetIntensity))")
    }

    func disableReduction() {
        guard isRunning else { return }

        isReductionEnabled = false
        preferences.lastReductionEnabled = false
        applyReductionIntensity(0)
        updateActiveStatus()
        AppLogger.shared.info("Vocal reduction disabled — passthrough")
    }

    private func applyReductionIntensity(_ value: Float) {
        neuralPipeline?.mixDSP.targetIntensity.store(value)
        neuralPipeline?.mixDSP.makeupGainDecibels.store(preferences.makeupGainDecibels)
    }

    /// Latest aligned dry/wet peak pair from the mix stage, or `nil` when no pipeline is running.
    /// Callers poll this at their own cadence — deliberately no timer here, so nothing ticks while
    /// the window is closed. `nil` (rather than a zeroed pair) lets the meter decay to silence
    /// instead of snapping to a flat line.
    var liveLevels: (dry: Float, wet: Float)? {
        guard let mixDSP = neuralPipeline?.mixDSP else { return nil }
        return (mixDSP.dryPeak.load(), mixDSP.wetPeak.load())
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

    func setTargetIntensity(_ value: Float) {
        preferences.targetIntensity = value
        if isReductionEnabled {
            applyReductionIntensity(value)
        }
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
            applyReductionIntensity(0)
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
        let backend = activeCaptureBackend ?? .processTap
        performInternalAudioChange {
            stopAudioUnitsOnly()
            stopProcessTap()

            do {
                switch backend {
                case .processTap:
                    if #available(macOS 14.2, *) {
                        do {
                            try startProcessTap()
                        } catch {
                            AppLogger.shared.warning(
                                "Process tap rebuild failed, falling back to BlackHole: \(error.localizedDescription)"
                            )
                            try startBlackHole()
                        }
                    } else {
                        try startBlackHole()
                    }
                case .blackHole:
                    try startBlackHole()
                }
                isReductionEnabled = shouldRestoreReduction
                if shouldRestoreReduction {
                    startNeuralPipelineIfNeeded()
                }
                applyReductionIntensity(isReductionEnabled ? preferences.targetIntensity : 0)
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

    fileprivate func handleInput(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let inputUnit, Int(frameCount) <= maxFramesPerCallback else {
            return kAudio_ParamError
        }

        let byteCount = frameCount * UInt32(MemoryLayout<Float>.size)
        captureBuffers[0].mNumberChannels = 1
        captureBuffers[0].mDataByteSize = byteCount
        captureBuffers[0].mData = UnsafeMutableRawPointer(processedLeft)
        captureBuffers[1].mNumberChannels = 1
        captureBuffers[1].mDataByteSize = byteCount
        captureBuffers[1].mData = UnsafeMutableRawPointer(processedRight)

        let renderStatus = AudioUnitRender(
            inputUnit,
            actionFlags,
            timestamp,
            busNumber,
            frameCount,
            captureBuffers.unsafeMutablePointer
        )
        guard renderStatus == noErr else { return renderStatus }

        ingestCapturedAudio(
            left: processedLeft,
            right: processedRight,
            frameCount: Int(frameCount)
        )
        return noErr
    }

    fileprivate func handleOutput(ioData: UnsafeMutablePointer<AudioBufferList>?, frameCount: UInt32) -> OSStatus {
        guard let ioData else { return kAudio_ParamError }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard buffers.count >= 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData
        else {
            return kAudio_ParamError
        }

        let left = leftData.bindMemory(to: Float.self, capacity: Int(frameCount))
        let right = rightData.bindMemory(to: Float.self, capacity: Int(frameCount))
        ringBuffer.read(left: left, right: right, frameCount: Int(frameCount))
        buffers[0].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        buffers[1].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        return noErr
    }

    private func requireBlackHole() throws -> AudioDevice {
        CoreAudioDevices.logDeviceSnapshot(reason: "require BlackHole")

        guard let blackHole = CoreAudioDevices.blackHoleDevice() else {
            if FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver") {
                throw AudioEngineError.blackHoleDriverInstalledButNotLoaded
            }
            throw AudioEngineError.blackHoleMissing
        }
        guard blackHole.inputChannelCount >= 2 else {
            throw AudioEngineError.unsupportedFormat(
                "BlackHole is visible to CoreAudio as \"\(blackHole.name)\", but reports input=\(blackHole.inputChannelCount), output=\(blackHole.outputChannelCount). Restart CoreAudio or reboot."
            )
        }
        return blackHole
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

    private func configureAudioUnits(inputDevice: AudioDevice, outputDevice: AudioDevice) throws {
        inputUnit = try makeHALUnit()
        outputUnit = try makeHALUnit()

        guard let inputUnit, let outputUnit else {
            throw AudioEngineError.coreAudio("Unable to create audio units", unspecifiedAudioStatus)
        }

        var format = stereoFloatFormat(sampleRate: sampleRate)
        try configureInputUnit(inputUnit, deviceID: inputDevice.id, format: &format)
        try configureOutputUnit(outputUnit, deviceID: outputDevice.id, format: &format)
    }

    private func configureInputUnit(_ unit: AudioUnit, deviceID: AudioDeviceID, format: inout AudioStreamBasicDescription) throws {
        var one: UInt32 = 1
        var zero: UInt32 = 0
        var mutableDeviceID = deviceID
        var callback = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size)), "Enable input IO")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size)), "Disable input unit output IO")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Set capture input device")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set input callback")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set input stream format")
        try checkCoreAudio(AudioUnitInitialize(unit), "Initialize input unit")
    }

    private func configureOutputUnit(_ unit: AudioUnit, deviceID: AudioDeviceID, format: inout AudioStreamBasicDescription) throws {
        var one: UInt32 = 1
        var zero: UInt32 = 0
        var mutableDeviceID = deviceID
        var callback = AURenderCallbackStruct(
            inputProc: outputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size)), "Enable output IO")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size)), "Disable output unit input IO")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Set physical output device")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set output callback")
        try checkCoreAudio(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set output stream format")
        try checkCoreAudio(AudioUnitInitialize(unit), "Initialize output unit")
    }

    private func makeHALUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError.coreAudio("Unable to find HAL output component", unspecifiedAudioStatus)
        }

        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw AudioEngineError.coreAudio("Unable to create HAL output unit", status)
        }
        return unit
    }

    private func startUnit(_ unit: AudioUnit?, label: String) throws {
        guard let unit else {
            throw AudioEngineError.coreAudio("Missing \(label) audio unit", unspecifiedAudioStatus)
        }
        try checkCoreAudio(AudioOutputUnitStart(unit), "Start \(label) unit")
    }

    private func stopAudioUnitsOnly() {
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        inputUnit = nil
        outputUnit = nil
        isRunning = false
        isReductionEnabled = false
        stopNeuralPipeline()
        ringBuffer.reset()
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

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    private func stereoFloatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

private let inputCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let engine = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.handleInput(
        actionFlags: actionFlags,
        timestamp: timestamp,
        busNumber: busNumber,
        frameCount: frameCount
    )
}

private let outputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let engine = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.handleOutput(ioData: ioData, frameCount: frameCount)
}
