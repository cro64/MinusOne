import Accelerate
import CoreML
import Foundation

/// HTDemucs CoreML wrapper for a specific Demucs v4 checkpoint variant.
final class CoreMLSeparationModel: AudioSeparationModel {
    let variant: SeparationModelVariant
    let name: String
    let modelSampleRate: Double = 44_100
    let preferredWindowSeconds: Double

    private let model: MLModel
    private let windowSampleCount: Int
    private let instrumentalStemIndices: [Int]
    private let inputArray: MLMultiArray
    private let inputLeftPtr: UnsafeMutablePointer<Float>
    private let inputRightPtr: UnsafeMutablePointer<Float>
    private let modelLeftScratch: UnsafeMutablePointer<Float>
    private let modelRightScratch: UnsafeMutablePointer<Float>
    private let instrumentalLeftScratch: UnsafeMutablePointer<Float>
    private let instrumentalRightScratch: UnsafeMutablePointer<Float>

    init(variant: SeparationModelVariant, captureSampleRate: Double = 48_000) throws {
        self.variant = variant
        self.name = variant.displayName
        let needsResample = abs(captureSampleRate - modelSampleRate) >= 1

        let modelURL = try Self.resolveModelURL(for: variant)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.allowLowPrecisionAccumulationOnGPU = true

        model = try MLModel(contentsOf: modelURL, configuration: configuration)

        guard let inputDescription = model.modelDescription.inputDescriptionsByName["audio"],
              let constraint = inputDescription.multiArrayConstraint,
              constraint.shape.count >= 3
        else {
            throw SeparationModelError.inferenceFailed("Unexpected model input shape")
        }

        windowSampleCount = constraint.shape[2].intValue
        preferredWindowSeconds = Double(windowSampleCount) / modelSampleRate

        if let sources = model.modelDescription.outputDescriptionsByName["sources"]?
            .multiArrayConstraint,
           sources.shape.count >= 2 {
            let outputStemCount = sources.shape[1].intValue
            instrumentalStemIndices = Self.resolveInstrumentalIndices(
                variant: variant,
                outputStemCount: outputStemCount
            )
            let outputShape = sources.shape.map(\.stringValue).joined(separator: "×")
            AppLogger.shared.info(
                "CoreML sources output: shape=\(outputShape) dtype=\(sources.dataType.rawValue)"
            )
        } else {
            instrumentalStemIndices = variant.instrumentalStemIndices
        }

        inputArray = try MLMultiArray(shape: [1, 2, NSNumber(value: windowSampleCount)], dataType: .float32)
        let inputBase = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        inputLeftPtr = inputBase
        inputRightPtr = inputBase.advanced(by: windowSampleCount)

        modelLeftScratch = UnsafeMutablePointer<Float>.allocate(capacity: windowSampleCount)
        modelRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: windowSampleCount)
        instrumentalLeftScratch = UnsafeMutablePointer<Float>.allocate(capacity: windowSampleCount)
        instrumentalRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: windowSampleCount)
        modelLeftScratch.initialize(repeating: 0, count: windowSampleCount)
        modelRightScratch.initialize(repeating: 0, count: windowSampleCount)
        instrumentalLeftScratch.initialize(repeating: 0, count: windowSampleCount)
        instrumentalRightScratch.initialize(repeating: 0, count: windowSampleCount)

        AppLogger.shared.info(
            "CoreML \(variant.rawValue) loaded from \(modelURL.path), window=\(windowSampleCount) samples (~\(String(format: "%.1f", preferredWindowSeconds)) s), stems=\(instrumentalStemIndices.count + 1), resample=\(needsResample)"
        )
    }

    deinit {
        modelLeftScratch.deinitialize(count: windowSampleCount)
        modelRightScratch.deinitialize(count: windowSampleCount)
        instrumentalLeftScratch.deinitialize(count: windowSampleCount)
        instrumentalRightScratch.deinitialize(count: windowSampleCount)
        modelLeftScratch.deallocate()
        modelRightScratch.deallocate()
        instrumentalLeftScratch.deallocate()
        instrumentalRightScratch.deallocate()
    }

    func separate(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) throws -> SeparationResult {
        let captureCount = frameCount
        let sources = try runModel(left: left, right: right, frameCount: captureCount, sampleRate: sampleRate)

        sumInstrumentalStems(from: sources)

        if abs(sampleRate - modelSampleRate) < 1, captureCount == windowSampleCount {
            return SeparationResult(
                instrumentalLeft: Array(UnsafeBufferPointer(start: instrumentalLeftScratch, count: windowSampleCount)),
                instrumentalRight: Array(UnsafeBufferPointer(start: instrumentalRightScratch, count: windowSampleCount))
            )
        }

        return SeparationResult(
            instrumentalLeft: resampleFromScratch(
                instrumentalLeftScratch,
                sourceCount: windowSampleCount,
                targetCount: captureCount
            ),
            instrumentalRight: resampleFromScratch(
                instrumentalRightScratch,
                sourceCount: windowSampleCount,
                targetCount: captureCount
            )
        )
    }

    /// Full per-stem separation (no summing) — used by Practice Mode's offline path.
    func separateAllStems(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) throws -> [SeparationStem: StemChannels] {
        let captureCount = frameCount
        let sources = try runModel(left: left, right: right, frameCount: captureCount, sampleRate: sampleRate)

        let needsResample = abs(sampleRate - modelSampleRate) >= 1 || captureCount != windowSampleCount
        var result: [SeparationStem: StemChannels] = [:]

        // dexxdean CoreML tensor order: vocals(0), drums(1), bass(2), other(3).
        for (stemIndex, stem) in [(0, SeparationStem.vocals), (1, .drums), (2, .bass), (3, .other)] {
            let (rawLeft, rawRight) = extractStem(stemIndex: stemIndex, from: sources)
            if needsResample {
                result[stem] = StemChannels(
                    left: resampleFromScratch(rawLeft, sourceCount: windowSampleCount, targetCount: captureCount, freeInput: true),
                    right: resampleFromScratch(rawRight, sourceCount: windowSampleCount, targetCount: captureCount, freeInput: true)
                )
            } else {
                result[stem] = StemChannels(
                    left: Array(UnsafeBufferPointer(start: rawLeft, count: windowSampleCount)),
                    right: Array(UnsafeBufferPointer(start: rawRight, count: windowSampleCount))
                )
                rawLeft.deallocate()
                rawRight.deallocate()
            }
        }

        return result
    }

    private func runModel(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) throws -> MLMultiArray {
        guard frameCount > 0 else {
            throw SeparationModelError.inferenceFailed("Empty capture window")
        }

        if abs(sampleRate - modelSampleRate) < 1 {
            fillModelInput(left: left, right: right, count: frameCount)
        } else {
            resampleIntoScratch(
                left: left,
                right: right,
                sourceCount: frameCount,
                targetCount: windowSampleCount
            )
            fillModelInput(
                left: modelLeftScratch,
                right: modelRightScratch,
                count: windowSampleCount
            )
        }

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": inputArray]))
        guard let sources = output.featureValue(for: "sources")?.multiArrayValue else {
            throw SeparationModelError.inferenceFailed("Missing sources output")
        }
        return sources
    }

    /// Extracts one stem's left/right channels into freshly allocated buffers of `windowSampleCount`.
    /// Caller owns and must deallocate the returned pointers.
    private func extractStem(
        stemIndex: Int,
        from sources: MLMultiArray
    ) -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let leftOut = UnsafeMutablePointer<Float>.allocate(capacity: windowSampleCount)
        let rightOut = UnsafeMutablePointer<Float>.allocate(capacity: windowSampleCount)
        leftOut.initialize(repeating: 0, count: windowSampleCount)
        rightOut.initialize(repeating: 0, count: windowSampleCount)

        if sources.dataType == .float32, let layout = StemTensorLayout(sources: sources), stemIndex < layout.stemCount {
            let sampleCount = min(windowSampleCount, layout.sampleCount)
            let base = sources.dataPointer.assumingMemoryBound(to: Float.self)
            let stemOffset = stemIndex * layout.stemStride
            let leftStem = base.advanced(by: stemOffset)
            let rightStem = leftStem.advanced(by: layout.channelStride)
            leftOut.update(from: leftStem, count: sampleCount)
            rightOut.update(from: rightStem, count: sampleCount)
            return (leftOut, rightOut)
        }

        let shape = sources.shape.map(\.intValue)
        let strides = sources.strides.map(\.intValue)
        let sampleCount = resolvedSampleCount(shape: shape)
        guard shape.count == 4, stemIndex < shape[1] else { return (leftOut, rightOut) }

        if sources.dataType == .float16, strides.count == 4 {
            let base = sources.dataPointer.assumingMemoryBound(to: Float16.self)
            for sample in 0..<sampleCount {
                let leftIndex = tensorOffset(strides: strides, stem: stemIndex, channel: 0, sample: sample)
                let rightIndex = tensorOffset(strides: strides, stem: stemIndex, channel: 1, sample: sample)
                leftOut[sample] = Float(base[leftIndex])
                rightOut[sample] = Float(base[rightIndex])
            }
        } else {
            for sample in 0..<sampleCount {
                leftOut[sample] = sources[[0, NSNumber(value: stemIndex), 0, NSNumber(value: sample)]].floatValue
                rightOut[sample] = sources[[0, NSNumber(value: stemIndex), 1, NSNumber(value: sample)]].floatValue
            }
        }

        return (leftOut, rightOut)
    }

    private func fillModelInput(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        let copyCount = min(count, windowSampleCount)
        inputLeftPtr.update(from: left, count: copyCount)
        inputRightPtr.update(from: right, count: copyCount)
        if copyCount < windowSampleCount {
            let padCount = windowSampleCount - copyCount
            inputLeftPtr.advanced(by: copyCount).update(repeating: 0, count: padCount)
            inputRightPtr.advanced(by: copyCount).update(repeating: 0, count: padCount)
        }
    }

    private func resampleIntoScratch(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        sourceCount: Int,
        targetCount: Int
    ) {
        resampleChannel(left, into: modelLeftScratch, sourceCount: sourceCount, targetCount: targetCount)
        resampleChannel(right, into: modelRightScratch, sourceCount: sourceCount, targetCount: targetCount)
    }

    private func resampleChannel(
        _ input: UnsafePointer<Float>,
        into output: UnsafeMutablePointer<Float>,
        sourceCount: Int,
        targetCount: Int
    ) {
        guard sourceCount > 0, targetCount > 0 else { return }
        let ratio = Double(sourceCount) / Double(targetCount)
        for index in 0..<targetCount {
            let sourcePosition = Double(index) * ratio
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, sourceCount - 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[index] = input[lower] * (1 - fraction) + input[upper] * fraction
        }
    }

    private func resampleFromScratch(
        _ input: UnsafeMutablePointer<Float>,
        sourceCount: Int,
        targetCount: Int,
        freeInput: Bool = false
    ) -> [Float] {
        defer { if freeInput { input.deallocate() } }
        var output = [Float](repeating: 0, count: targetCount)
        guard sourceCount > 0, targetCount > 0 else { return output }
        let ratio = Double(sourceCount) / Double(targetCount)
        for index in 0..<targetCount {
            let sourcePosition = Double(index) * ratio
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, sourceCount - 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[index] = input[lower] * (1 - fraction) + input[upper] * fraction
        }
        return output
    }

    private func sumInstrumentalStems(from sources: MLMultiArray) {
        instrumentalLeftScratch.update(repeating: 0, count: windowSampleCount)
        instrumentalRightScratch.update(repeating: 0, count: windowSampleCount)

        // FP16 models (HTDemucs_CoreML_FP16) output float16 — vDSP on a Float* view overruns the buffer.
        if sources.dataType == .float32, let layout = StemTensorLayout(sources: sources) {
            sumInstrumentalStemsFloat32(from: sources, layout: layout)
        } else {
            sumInstrumentalStemsScalar(from: sources)
        }
    }

    /// Packed `[1, stems, 2, samples]` float32 layout only.
    private struct StemTensorLayout {
        let stemCount: Int
        let sampleCount: Int
        let stemStride: Int
        let channelStride: Int

        init?(sources: MLMultiArray) {
            guard sources.dataType == .float32 else { return nil }
            let shape = sources.shape.map(\.intValue)
            let strides = sources.strides.map(\.intValue)
            guard shape.count == 4,
                  shape[0] == 1,
                  shape[2] == 2,
                  strides.count == 4,
                  strides[3] == 1,
                  strides[2] == shape[3],
                  strides[1] == shape[2] * shape[3],
                  strides[0] == shape[1] * shape[2] * shape[3]
            else { return nil }

            stemCount = shape[1]
            sampleCount = shape[3]
            channelStride = strides[2]
            stemStride = strides[1]
        }
    }

    private func sumInstrumentalStemsFloat32(from sources: MLMultiArray, layout: StemTensorLayout) {
        let sampleCount = min(windowSampleCount, layout.sampleCount)
        let base = sources.dataPointer.assumingMemoryBound(to: Float.self)

        for stemIndex in instrumentalStemIndices where stemIndex < layout.stemCount {
            let stemOffset = stemIndex * layout.stemStride
            let leftStem = base.advanced(by: stemOffset)
            let rightStem = leftStem.advanced(by: layout.channelStride)
            vDSP_vadd(leftStem, 1, instrumentalLeftScratch, 1, instrumentalLeftScratch, 1, vDSP_Length(sampleCount))
            vDSP_vadd(rightStem, 1, instrumentalRightScratch, 1, instrumentalRightScratch, 1, vDSP_Length(sampleCount))
        }
    }

    private func sumInstrumentalStemsScalar(from sources: MLMultiArray) {
        let shape = sources.shape.map(\.intValue)
        let strides = sources.strides.map(\.intValue)
        let sampleCount = resolvedSampleCount(shape: shape)

        if sources.dataType == .float16, shape.count == 4, strides.count == 4 {
            let base = sources.dataPointer.assumingMemoryBound(to: Float16.self)
            for stemIndex in instrumentalStemIndices {
                guard stemIndex < shape[1] else { continue }
                for sample in 0..<sampleCount {
                    let leftIndex = tensorOffset(strides: strides, stem: stemIndex, channel: 0, sample: sample)
                    let rightIndex = tensorOffset(strides: strides, stem: stemIndex, channel: 1, sample: sample)
                    instrumentalLeftScratch[sample] += Float(base[leftIndex])
                    instrumentalRightScratch[sample] += Float(base[rightIndex])
                }
            }
            return
        }

        for stemIndex in instrumentalStemIndices {
            for sample in 0..<sampleCount {
                instrumentalLeftScratch[sample] += sources[[0, NSNumber(value: stemIndex), 0, NSNumber(value: sample)]].floatValue
                instrumentalRightScratch[sample] += sources[[0, NSNumber(value: stemIndex), 1, NSNumber(value: sample)]].floatValue
            }
        }
    }

    private func resolvedSampleCount(shape: [Int]) -> Int {
        guard shape.count == 4 else { return windowSampleCount }
        if shape[2] == 2 {
            return min(windowSampleCount, shape[3])
        }
        if shape[3] == 2 {
            return min(windowSampleCount, shape[2])
        }
        return windowSampleCount
    }

    private func tensorOffset(strides: [Int], stem: Int, channel: Int, sample: Int) -> Int {
        stem * strides[1] + channel * strides[2] + sample * strides[3]
    }

    private static func resolveInstrumentalIndices(
        variant: SeparationModelVariant,
        outputStemCount: Int
    ) -> [Int] {
        switch outputStemCount {
        case 4:
            return [1, 2, 3]
        default:
            return variant.instrumentalStemIndices
        }
    }

    private static func resolveModelURL(for variant: SeparationModelVariant) throws -> URL {
        for candidate in SeparationModelFactory.modelSearchPaths(for: variant) {
            switch candidate.pathExtension {
            case "mlmodelc":
                return candidate
            case "mlpackage":
                return try compilePackageIfNeeded(at: candidate, variant: variant)
            default:
                continue
            }
        }

        let searched = SeparationModelFactory.modelSearchPaths(for: variant).map(\.path).joined(separator: ", ")
        throw SeparationModelError.modelNotFound(searched.isEmpty ? "no search paths" : searched)
    }

    private static func compilePackageIfNeeded(at packageURL: URL, variant: SeparationModelVariant) throws -> URL {
        let compiledURL = SeparationModelFactory.compiledModelURL(adjacentTo: packageURL, variant: variant)
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            return compiledURL
        }

        AppLogger.shared.info("Compiling CoreML \(variant.rawValue) (~20 s, one-time)...")
        do {
            let temporaryCompiled = try MLModel.compileModel(at: packageURL)
            if FileManager.default.fileExists(atPath: compiledURL.path) {
                try FileManager.default.removeItem(at: compiledURL)
            }
            try FileManager.default.moveItem(at: temporaryCompiled, to: compiledURL)
            AppLogger.shared.info("Compiled separation model saved to \(compiledURL.path)")
            return compiledURL
        } catch {
            throw SeparationModelError.compileFailed(error.localizedDescription)
        }
    }
}
