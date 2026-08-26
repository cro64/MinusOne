import Foundation

/// Reduces stored peak columns to the number of columns actually being drawn.
///
/// This is the operation the whole single-resolution sidecar decision rests on: because the stored
/// level is deeper than any useful zoom, the renderer only ever bins *downward*, which is one pass
/// over at most ~41,000 values.
enum PeakBinning {
    /// Groups `sourceCount` columns into `targetCount`, keeping the extremes of each group and the
    /// root-mean-square of its RMS values.
    ///
    /// `column` is a closure rather than an array so callers can read straight out of a
    /// memory-mapped sidecar without materialising it. It must tolerate any index in
    /// `0..<sourceCount` and is never called outside that range.
    static func rebin(targetCount: Int, sourceCount: Int, column: (Int) -> PeakColumn) -> [PeakColumn] {
        guard targetCount > 0 else { return [] }
        guard sourceCount > 0 else { return Array(repeating: .silent, count: targetCount) }

        var result: [PeakColumn] = []
        result.reserveCapacity(targetCount)

        for index in 0..<targetCount {
            let start = index * sourceCount / targetCount
            // At least one source column per output column, so upsampling repeats rather than
            // producing a gap.
            let end = min(sourceCount, max(start + 1, (index + 1) * sourceCount / targetCount))

            var minimum = Float.greatestFiniteMagnitude
            var maximum = -Float.greatestFiniteMagnitude
            var squareSum = 0.0
            var count = 0

            for sourceIndex in start..<end {
                let source = column(sourceIndex)
                minimum = Swift.min(minimum, source.minimum)
                maximum = Swift.max(maximum, source.maximum)
                squareSum += Double(source.rms) * Double(source.rms)
                count += 1
            }

            guard count > 0 else {
                result.append(.silent)
                continue
            }
            result.append(PeakColumn(
                minimum: minimum,
                maximum: maximum,
                rms: Float((squareSum / Double(count)).squareRoot())
            ))
        }
        return result
    }
}
