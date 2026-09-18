import Foundation

/// Demucs v4 checkpoint used for Neural mode (HTDemucs / Balanced).
enum SeparationModelVariant: String, CaseIterable, Codable, Identifiable {
    /// Default v4 — 4-stem separation, good balance of speed and quality.
    case balanced = "htdemucs"

    var id: String { rawValue }

    var displayName: String { "Demucs" }

    /// Hugging Face repo that hosts the CoreML package.
    var huggingFaceRepoID: String { "dexxdean/htdemucs-coreml" }

    /// Folder name inside the HF repo to download (installed on disk as `packageFileName`).
    var huggingFaceSourcePackageName: String { "HTDemucs_CoreML_FP16.mlpackage" }

    var approximateDownloadSizeText: String { "~200 MB" }

    /// Short origin blurb for the onboarding info popover.
    var sourceAttributionText: String {
        """
        Based on Meta’s Demucs v4 (htdemucs) — open-source music source separation.

        The CoreML package MinusOne downloads is published on Hugging Face by dexxdean (dexxdean/htdemucs-coreml), converted for Apple Silicon.
        """
    }

    var sourcePageURL: URL? {
        URL(string: "https://huggingface.co/dexxdean/htdemucs-coreml")
    }

    /// Primary on-disk package name (Demucs checkpoint id).
    var packageFileName: String {
        "\(rawValue).mlpackage"
    }

    var compiledFileName: String {
        "\(rawValue).mlmodelc"
    }

    /// Legacy balanced install from early MinusOne builds.
    static let legacyBalancedPackage = "HTDemucs_CoreML.mlpackage"
    static let legacyBalancedCompiled = "HTDemucs_CoreML.mlmodelc"

    static func fromPersisted(_ raw: String) -> SeparationModelVariant? {
        if let variant = SeparationModelVariant(rawValue: raw) {
            return variant
        }
        switch raw {
        case "HTDemucs_CoreML", "balanced", "htdemucs_ft", "htdemucs_6s":
            // Retired Fine-Tuned / Six-Stem prefs fall back to Balanced.
            return .balanced
        default:
            return nil
        }
    }
}
