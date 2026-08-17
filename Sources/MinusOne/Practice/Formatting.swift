import Foundation

extension Double {
    /// Formats a duration in seconds as `m:ss` (e.g. `125` → `"2:05"`). Non-finite or negative
    /// values (a still-loading clip's duration, etc.) fall back to `"0:00"`.
    var formattedAsDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
