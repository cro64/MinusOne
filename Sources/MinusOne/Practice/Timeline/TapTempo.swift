import Foundation

/// Turns a series of taps into a tempo.
///
/// The median of recent intervals rather than their mean: tapping is done by a human against music
/// they are listening to, so one late tap in a handful is normal and a mean would carry it into the
/// answer. The idle reset is what lets someone stop, listen, and start again without averaging
/// across the pause.
struct TapTempo {
    private let idleResetSeconds: Double
    private let maximumTaps: Int
    private var taps: [Double] = []

    init(idleResetSeconds: Double = 2.0, maximumTaps: Int = 8) {
        self.idleResetSeconds = idleResetSeconds
        self.maximumTaps = max(2, maximumTaps)
    }

    var tapCount: Int { taps.count }

    mutating func reset() { taps.removeAll() }

    /// Records a tap and returns the tempo it implies, or `nil` while there is not enough to go on.
    mutating func tap(at time: Double) -> Double? {
        if let last = taps.last, time - last > idleResetSeconds || time < last {
            taps = [time]
            return nil
        }
        taps.append(time)
        if taps.count > maximumTaps { taps.removeFirst(taps.count - maximumTaps) }
        guard taps.count >= 2 else { return nil }

        var intervals: [Double] = []
        for index in 1..<taps.count {
            let interval = taps[index] - taps[index - 1]
            if interval > 0 { intervals.append(interval) }
        }
        guard !intervals.isEmpty else { return nil }

        intervals.sort()
        let middle = intervals.count / 2
        let median = intervals.count.isMultiple(of: 2)
            ? (intervals[middle - 1] + intervals[middle]) / 2
            : intervals[middle]
        guard median > 0 else { return nil }
        return 60 / median
    }
}
