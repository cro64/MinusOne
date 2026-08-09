import Foundation

struct SeparationResult {
    let instrumentalLeft: [Float]
    let instrumentalRight: [Float]
}

/// Individual Demucs source stems (dexxdean CoreML tensor order: vocals, drums, bass, other).
enum SeparationStem: String, CaseIterable {
    case vocals
    case drums
    case bass
    case other

    var displayName: String {
        switch self {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        }
    }
}

struct StemChannels {
    let left: [Float]
    let right: [Float]
}

protocol AudioSeparationModel: AnyObject {
    var variant: SeparationModelVariant { get }
    var name: String { get }
    var modelSampleRate: Double { get }
    var preferredWindowSeconds: Double { get }

    func separate(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) throws -> SeparationResult

    /// Full per-stem separation (no summing) for offline/full-quality use — Practice Mode.
    func separateAllStems(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) throws -> [SeparationStem: StemChannels]
}

enum SeparationModelError: Error, LocalizedError {
    case modelNotFound(String)
    case compileFailed(String)
    case inferenceFailed(String)
    case unsupportedSampleRate(Double)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Separation model not found at \(path). Run Scripts/download-model.sh."
        case .compileFailed(let message):
            return "Failed to compile separation model: \(message)"
        case .inferenceFailed(let message):
            return "Separation inference failed: \(message)"
        case .unsupportedSampleRate(let rate):
            return "Unsupported sample rate \(rate) Hz for separation model."
        }
    }
}

enum SeparationModelFactory {
    static let modelsDirectoryName = "MinusOne/Models"

    static let modelInstallHint = """
        Download a Neural model from the welcome screen, or run Scripts/download-model.sh.
        """

    static func isAvailable(_ variant: SeparationModelVariant) -> Bool {
        !modelSearchPaths(for: variant).isEmpty
    }

    static func loadModel(variant: SeparationModelVariant, captureSampleRate: Double = 48_000) throws -> AudioSeparationModel {
        guard isAvailable(variant) else {
            throw SeparationModelError.modelNotFound(
                modelSearchPaths(for: variant).map(\.path).joined(separator: ", ")
            )
        }
        let model = try CoreMLSeparationModel(variant: variant, captureSampleRate: captureSampleRate)
        AppLogger.shared.info("Loaded CoreML separation model: \(model.name) (\(variant.rawValue))")
        return model
    }

    static func modelSearchPaths(for variant: SeparationModelVariant) -> [URL] {
        var paths: [URL] = []

        if let bundledCompiled = Bundle.main.url(
            forResource: variant.rawValue,
            withExtension: "mlmodelc"
        ) {
            paths.append(bundledCompiled)
        }
        if let bundledPackage = Bundle.main.url(
            forResource: variant.rawValue,
            withExtension: "mlpackage"
        ) {
            paths.append(bundledPackage)
        }

        if variant == .balanced {
            if let legacyCompiled = Bundle.main.url(
                forResource: "HTDemucs_CoreML",
                withExtension: "mlmodelc"
            ) {
                paths.append(legacyCompiled)
            }
            if let legacyPackage = Bundle.main.url(
                forResource: "HTDemucs_CoreML",
                withExtension: "mlpackage"
            ) {
                paths.append(legacyPackage)
            }
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        let modelsDir = appSupport.appendingPathComponent(modelsDirectoryName, isDirectory: true)
        paths.append(modelsDir.appendingPathComponent(variant.compiledFileName, isDirectory: true))
        paths.append(modelsDir.appendingPathComponent(variant.packageFileName, isDirectory: true))

        if variant == .balanced {
            paths.append(
                modelsDir.appendingPathComponent(SeparationModelVariant.legacyBalancedCompiled, isDirectory: true)
            )
            paths.append(
                modelsDir.appendingPathComponent(SeparationModelVariant.legacyBalancedPackage, isDirectory: true)
            )
        }

        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func compiledModelURL(adjacentTo packageURL: URL, variant: SeparationModelVariant) -> URL {
        packageURL.deletingLastPathComponent().appendingPathComponent(variant.compiledFileName, isDirectory: true)
    }
}
