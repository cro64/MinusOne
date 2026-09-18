import CAtomics
import Foundation

enum NeuralPipelineState: Equatable {
    case idle
    case warmingUp
    case ready
    case error(String)
}

final class NeuralSeparationPipeline {
    private let model: AudioSeparationModel
    private let sampleRate: Double
    private let windowSamples: Int
    private let hopSamples: Int
    private let delaySamples: Int

    private let inputBuffer: RollingStereoBuffer
    private let delayLine: StereoDelayLine
    private let stitcher: HopSpliceStitcher
    private let discontinuityDetector: AudioDiscontinuityDetector
    let mixDSP: NeuralMixDSP

    /// Live carries all 4 separated stems through to the mixer instead of pre-summing 3 of them
    /// into one "instrumental" stream, so each stem needs its own output ring buffer and its own
    /// priming/progress bookkeeping — they all come from the same per-hop `separateAllStems()` call,
    /// but `process()` (audio thread) reads them independently of `inferenceLoop()` (inference
    /// thread) writing them, so each stem's "how far has this one actually been written" state has
    /// to be tracked (and made atomic) separately, not assumed to move in lockstep.
    private final class StemState {
        let outputBuffer: RollingStereoBuffer
        let scratchLeft: UnsafeMutablePointer<Float>
        let scratchRight: UnsafeMutablePointer<Float>
        let outputPrimedEpoch: UnsafeMutablePointer<mo_atomic_uint64_t>
        let latestOutputEnd: UnsafeMutablePointer<mo_atomic_uint64_t>
        var hasPrimedOutput = false

        init(bufferCapacity: Int, scratchCapacity: Int) {
            outputBuffer = RollingStereoBuffer(capacitySamples: bufferCapacity)
            scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
            scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
            scratchLeft.initialize(repeating: 0, count: scratchCapacity)
            scratchRight.initialize(repeating: 0, count: scratchCapacity)
            outputPrimedEpoch = UnsafeMutablePointer<mo_atomic_uint64_t>.allocate(capacity: 1)
            latestOutputEnd = UnsafeMutablePointer<mo_atomic_uint64_t>.allocate(capacity: 1)
            mo_atomic_uint64_init(outputPrimedEpoch, 0)
            mo_atomic_uint64_init(latestOutputEnd, 0)
        }

        deinit {
            scratchLeft.deallocate()
            scratchRight.deallocate()
            outputPrimedEpoch.deallocate()
            latestOutputEnd.deallocate()
        }

        func resetForFlush() {
            outputBuffer.clearSamples()
            hasPrimedOutput = false
            mo_atomic_uint64_store(outputPrimedEpoch, 0)
            mo_atomic_uint64_store(latestOutputEnd, 0)
        }
    }

    private let stemStates: [SeparationStem: StemState]

    private let inferenceQueue = DispatchQueue(label: "com.minusone.neural-inference", qos: .utility)
    private var inferenceWorkItem: DispatchWorkItem?
    private var isInferenceRunning = false
    private let nextInferenceEnd: UnsafeMutablePointer<mo_atomic_uint64_t>
    private let pipelineEpoch: UnsafeMutablePointer<mo_atomic_uint64_t>
    private var inferenceEpoch: UInt64 = 0
    private var pipelineState: NeuralPipelineState = .idle
    private var stateChangeHandler: ((NeuralPipelineState) -> Void)?
    private var flushGraceUntilPosition: UInt64 = 0
    private var warmupStartedAt: Date?

    private let scratchDelayedLeft: UnsafeMutablePointer<Float>
    private let scratchDelayedRight: UnsafeMutablePointer<Float>
    private let windowLeft: UnsafeMutablePointer<Float>
    private let windowRight: UnsafeMutablePointer<Float>
    private let maxFramesPerCallback: Int

    init(
        model: AudioSeparationModel,
        sampleRate: Double,
        windowSeconds: Double = 6.0,
        hopSeconds: Double = 1.5,
        makeupGainDecibels: Float,
        rampDurationMilliseconds: Float,
        maxFramesPerCallback: Int = 8_192
    ) {
        self.model = model
        self.sampleRate = sampleRate
        self.maxFramesPerCallback = maxFramesPerCallback

        windowSamples = max(1, Int(sampleRate * windowSeconds))
        hopSamples = max(1, Int(sampleRate * hopSeconds))
        delaySamples = windowSamples

        let bufferCapacity = windowSamples * 4
        inputBuffer = RollingStereoBuffer(capacitySamples: bufferCapacity)
        delayLine = StereoDelayLine(requiredDelaySamples: delaySamples, headroomSamples: maxFramesPerCallback)
        stitcher = HopSpliceStitcher(windowLength: windowSamples, hopLength: hopSamples, sampleRate: sampleRate)
        discontinuityDetector = AudioDiscontinuityDetector(sampleRate: sampleRate)
        mixDSP = NeuralMixDSP(makeupGainDecibels: makeupGainDecibels, rampDurationMilliseconds: rampDurationMilliseconds)

        stemStates = Dictionary(
            uniqueKeysWithValues: SeparationStem.allCases.map {
                ($0, StemState(bufferCapacity: bufferCapacity, scratchCapacity: maxFramesPerCallback))
            }
        )

        nextInferenceEnd = UnsafeMutablePointer<mo_atomic_uint64_t>.allocate(capacity: 1)
        pipelineEpoch = UnsafeMutablePointer<mo_atomic_uint64_t>.allocate(capacity: 1)
        mo_atomic_uint64_init(nextInferenceEnd, 0)
        mo_atomic_uint64_init(pipelineEpoch, 0)

        scratchDelayedLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        scratchDelayedRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        scratchDelayedLeft.initialize(repeating: 0, count: maxFramesPerCallback)
        scratchDelayedRight.initialize(repeating: 0, count: maxFramesPerCallback)

        windowLeft = UnsafeMutablePointer<Float>.allocate(capacity: windowSamples)
        windowRight = UnsafeMutablePointer<Float>.allocate(capacity: windowSamples)
        windowLeft.initialize(repeating: 0, count: windowSamples)
        windowRight.initialize(repeating: 0, count: windowSamples)
    }

    deinit {
        stopInference()
        nextInferenceEnd.deallocate()
        pipelineEpoch.deallocate()
        scratchDelayedLeft.deinitialize(count: maxFramesPerCallback)
        scratchDelayedRight.deinitialize(count: maxFramesPerCallback)
        scratchDelayedLeft.deallocate()
        scratchDelayedRight.deallocate()
        windowLeft.deinitialize(count: windowSamples)
        windowRight.deinitialize(count: windowSamples)
        windowLeft.deallocate()
        windowRight.deallocate()
    }

    func setStateChangeHandler(_ handler: @escaping (NeuralPipelineState) -> Void) {
        stateChangeHandler = handler
        handler(pipelineState)
    }

    var state: NeuralPipelineState {
        pipelineState
    }

    var playbackDelaySeconds: Double {
        Double(delaySamples) / sampleRate
    }

    /// Hard lower bound on time-to-ready: how much audio has to be buffered (`delaySamples` for the
    /// dry path to catch up, plus one more `windowSamples` for the first inference window to exist)
    /// before the pipeline can possibly mark itself `.ready`. Fixed once the pipeline is built —
    /// independent of how many stems are being mixed.
    var estimatedWarmupSeconds: Double {
        Double(delaySamples + windowSamples) / sampleRate
    }

    /// Seconds left in the current warm-up episode, or `nil` when not warming up. Ticks down from
    /// `estimatedWarmupSeconds` but never goes negative — if inference is still catching up past
    /// the estimate, callers should just stop showing a number rather than go negative.
    var remainingWarmupSeconds: Double? {
        guard case .warmingUp = pipelineState, let warmupStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(warmupStartedAt)
        return max(0, estimatedWarmupSeconds - elapsed)
    }

    func start() {
        reset()
        warmupStartedAt = Date()
        setState(.warmingUp)
        startInferenceLoop()
        AppLogger.shared.info(
            "Neural pipeline started: window=\(windowSamples) hop=\(hopSamples) delay=\(delaySamples) model=\(model.name)"
        )
    }

    func stop() {
        stopInference()
        reset()
        warmupStartedAt = nil
        setState(.idle)
    }

    func reset() {
        inputBuffer.reset()
        delayLine.reset()
        mixDSP.reset()
        discontinuityDetector.reset()
        for stem in SeparationStem.allCases {
            stemStates[stem]?.resetForFlush()
        }
        mo_atomic_uint64_store(nextInferenceEnd, UInt64(windowSamples))
        mo_atomic_uint64_store(pipelineEpoch, mo_atomic_uint64_load(pipelineEpoch) + 1)
        inferenceEpoch = mo_atomic_uint64_load(pipelineEpoch)
    }

    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0, frameCount <= maxFramesPerCallback else { return }

        inputBuffer.write(left: inputLeft, right: inputRight, frameCount: frameCount)

        let writePosition = inputBuffer.writePosition
        if discontinuityDetector.evaluate(
            left: inputLeft,
            right: inputRight,
            frameCount: frameCount,
            absolutePosition: writePosition
        ), writePosition >= flushGraceUntilPosition {
            flushAfterDiscontinuity(at: writePosition)
        }

        updateWarmupState(writePosition: writePosition)

        let reductionActive = mixDSP.masterEnabled.load() > 0.5

        delayLine.process(
            inputLeft: inputLeft,
            inputRight: inputRight,
            outputLeft: scratchDelayedLeft,
            outputRight: scratchDelayedRight,
            frameCount: frameCount,
            delaySamples: delaySamples
        )

        guard delayLine.isDelayReady(delaySamples: delaySamples) else {
            outputLeft.update(from: inputLeft, count: frameCount)
            outputRight.update(from: inputRight, count: frameCount)
            return
        }

        let playbackLead = UInt64(frameCount) + UInt64(delaySamples)
        let playbackStart = writePosition >= playbackLead ? writePosition - playbackLead : 0
        let playbackEnd = playbackStart + UInt64(frameCount)
        let currentEpoch = mo_atomic_uint64_load(pipelineEpoch)
        let allStemsPrimedAndCovering = SeparationStem.allCases.allSatisfy { stem in
            guard let state = stemStates[stem] else { return false }
            let isPrimed = mo_atomic_uint64_load(state.outputPrimedEpoch) == currentEpoch
            let covers = playbackEnd <= mo_atomic_uint64_load(state.latestOutputEnd)
            return isPrimed && covers
        }
        let canMix = reductionActive
            && writePosition >= playbackLead + UInt64(windowSamples)
            && allStemsPrimedAndCovering

        guard canMix else {
            outputLeft.update(from: scratchDelayedLeft, count: frameCount)
            outputRight.update(from: scratchDelayedRight, count: frameCount)
            return
        }

        var stemBuffers: [SeparationStem: (left: UnsafePointer<Float>, right: UnsafePointer<Float>)] = [:]
        for stem in SeparationStem.allCases {
            guard let state = stemStates[stem] else { continue }
            state.outputBuffer.read(
                atAbsolutePosition: playbackStart,
                left: state.scratchLeft,
                right: state.scratchRight,
                frameCount: frameCount
            )
            stemBuffers[stem] = (left: UnsafePointer(state.scratchLeft), right: UnsafePointer(state.scratchRight))
        }

        mixDSP.process(
            rawLeft: scratchDelayedLeft,
            rawRight: scratchDelayedRight,
            stems: stemBuffers,
            outputLeft: outputLeft,
            outputRight: outputRight,
            frameCount: frameCount,
            sampleRate: sampleRate
        )
    }

    private func flushAfterDiscontinuity(at writePosition: UInt64) {
        resyncPlayback(at: writePosition)
        AppLogger.shared.info("Neural pipeline flushed after audio discontinuity at sample \(writePosition)")
    }

    private func resyncPlayback(at writePosition: UInt64) {
        delayLine.reset()
        for stem in SeparationStem.allCases {
            stemStates[stem]?.resetForFlush()
        }
        mo_atomic_uint64_store(nextInferenceEnd, writePosition + UInt64(windowSamples))
        mo_atomic_uint64_store(pipelineEpoch, mo_atomic_uint64_load(pipelineEpoch) + 1)
        flushGraceUntilPosition = writePosition + UInt64(sampleRate * 3)
        // A discontinuity mid-session is a genuine new warm-up episode — the pipeline really did
        // re-buffer from scratch — so restart the countdown rather than leaving it at whatever was
        // left from before the flush.
        warmupStartedAt = Date()
        setState(.warmingUp)
    }

    private func tryMarkReady(writePosition: UInt64) {
        guard case .warmingUp = pipelineState else { return }
        let currentEpoch = mo_atomic_uint64_load(pipelineEpoch)
        let allStemsPrimed = SeparationStem.allCases.allSatisfy { stem in
            guard let state = stemStates[stem] else { return false }
            return mo_atomic_uint64_load(state.outputPrimedEpoch) == currentEpoch
        }
        let enoughBuffered = writePosition >= UInt64(delaySamples + windowSamples)
        if allStemsPrimed, enoughBuffered {
            setState(.ready)
        }
    }

    private func updateWarmupState(writePosition: UInt64) {
        tryMarkReady(writePosition: writePosition)
    }

    private func setState(_ newState: NeuralPipelineState) {
        guard pipelineState != newState else { return }
        pipelineState = newState
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateChangeHandler?(self.pipelineState)
        }
    }

    private func startInferenceLoop() {
        guard !isInferenceRunning else { return }
        isInferenceRunning = true

        let work = DispatchWorkItem { [weak self] in
            self?.inferenceLoop()
        }
        inferenceWorkItem = work
        inferenceQueue.async(execute: work)
    }

    private func stopInference() {
        inferenceWorkItem?.cancel()
        inferenceWorkItem = nil
        isInferenceRunning = false
    }

    private func syncInferenceEpochIfNeeded() {
        let epoch = mo_atomic_uint64_load(pipelineEpoch)
        guard epoch != inferenceEpoch else { return }
        inferenceEpoch = epoch
        for stem in SeparationStem.allCases {
            stemStates[stem]?.hasPrimedOutput = false
        }
    }

    private func inferenceLoop() {
        while isInferenceRunning, !(inferenceWorkItem?.isCancelled ?? true) {
            syncInferenceEpochIfNeeded()

            let writePosition = inputBuffer.writePosition
            let inferenceEnd = mo_atomic_uint64_load(nextInferenceEnd)

            if shouldThrottleInference(writePosition: writePosition) {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            guard writePosition >= inferenceEnd else {
                let samplesRemaining = inferenceEnd - writePosition
                let sleepSeconds = min(0.1, max(0.01, Double(samplesRemaining) / sampleRate))
                Thread.sleep(forTimeInterval: sleepSeconds)
                continue
            }

            inputBuffer.copyWindow(
                endingBefore: inferenceEnd,
                length: windowSamples,
                intoLeft: windowLeft,
                intoRight: windowRight
            )

            let epochAtStart = mo_atomic_uint64_load(pipelineEpoch)

            do {
                let stems = try model.separateAllStems(
                    left: windowLeft,
                    right: windowRight,
                    frameCount: windowSamples,
                    sampleRate: sampleRate
                )

                guard epochAtStart == mo_atomic_uint64_load(pipelineEpoch) else { continue }

                // All 4 stems come from this one hop's inference — stitch them in one tight loop
                // (no yielding in between) so `process()`, running concurrently on the audio thread,
                // never sees some stems advanced past a hop boundary while others haven't.
                for stem in SeparationStem.allCases {
                    guard let state = stemStates[stem], let channels = stems[stem] else { continue }
                    let instrumentalLeft = channels.left
                    let instrumentalRight = channels.right

                    if !state.hasPrimedOutput {
                        guard inferenceEnd >= UInt64(windowSamples) else { continue }
                        let startPosition = inferenceEnd - UInt64(windowSamples)
                        instrumentalLeft.withUnsafeBufferPointer { leftPtr in
                            instrumentalRight.withUnsafeBufferPointer { rightPtr in
                                stitcher.writeInitialWindow(
                                    left: leftPtr.baseAddress!,
                                    right: rightPtr.baseAddress!,
                                    atAbsolutePosition: startPosition,
                                    into: state.outputBuffer
                                )
                            }
                        }
                        state.hasPrimedOutput = true
                        mo_atomic_uint64_store(state.outputPrimedEpoch, mo_atomic_uint64_load(pipelineEpoch))
                        markOutputWritten(through: startPosition + UInt64(windowSamples), for: state)
                    } else {
                        let hopStartIndex = windowSamples - hopSamples
                        let hopStartPosition = inferenceEnd - UInt64(hopSamples)
                        instrumentalLeft.withUnsafeBufferPointer { leftPtr in
                            instrumentalRight.withUnsafeBufferPointer { rightPtr in
                                stitcher.writeHopTail(
                                    left: leftPtr.baseAddress!.advanced(by: hopStartIndex),
                                    right: rightPtr.baseAddress!.advanced(by: hopStartIndex),
                                    atAbsolutePosition: hopStartPosition,
                                    into: state.outputBuffer
                                )
                            }
                        }
                        markOutputWritten(through: hopStartPosition + UInt64(hopSamples), for: state)
                    }
                }

                tryMarkReady(writePosition: inputBuffer.writePosition)
                mo_atomic_uint64_store(nextInferenceEnd, inferenceEnd + UInt64(hopSamples))
            } catch {
                AppLogger.shared.error("Neural inference failed: \(error.localizedDescription)")
                setState(.error(error.localizedDescription))
                isInferenceRunning = false
                return
            }
        }
    }

    private func markOutputWritten(through endPosition: UInt64, for state: StemState) {
        let current = mo_atomic_uint64_load(state.latestOutputEnd)
        if endPosition > current {
            mo_atomic_uint64_store(state.latestOutputEnd, endPosition)
        }
    }

    /// When Live is off, instrumental output is not played — keep the buffers warm but don't burn
    /// CPU. Gated on `masterEnabled` (Live on/off), not on the individual stem levels: muting every
    /// stem while Live stays on intentionally does NOT throttle, since that's still "Live is on,"
    /// just mixed to silence.
    private func shouldThrottleInference(writePosition: UInt64) -> Bool {
        let allPrimed = SeparationStem.allCases.allSatisfy { stemStates[$0]?.hasPrimedOutput ?? false }
        guard allPrimed, mixDSP.masterEnabled.load() < 0.5 else { return false }

        let frontier = SeparationStem.allCases.compactMap { stemStates[$0].map { mo_atomic_uint64_load($0.latestOutputEnd) } }.min() ?? 0
        guard writePosition > UInt64(delaySamples) else { return false }

        let playbackHead = writePosition - UInt64(delaySamples)
        return frontier >= playbackHead + UInt64(hopSamples)
    }
}
