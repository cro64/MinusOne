import Foundation

/// The single source of truth for converting between clip time and musical position.
///
/// Every view that draws or snaps to the grid reads a `BeatGrid` and none performs its own bar or
/// beat arithmetic. That rule is the Phase 3 analogue of the `Viewport`-only rule the timeline is
/// built on, and it exists for the same reason: the ruler's ticks, the loop snapper and the
/// draggable downbeat must land on identical instants, not merely similar ones.
struct BeatGrid: Equatable {
    /// A musical position. `bar` is 1-based at the downbeat and counts *down* before it, so a clip
    /// that starts mid-bar gets bar 0, -1, … rather than a run of 1s.
    struct Position: Equatable {
        let bar: Int
        let beat: Int
    }

    /// Beats per minute. Clamped away from zero so the arithmetic can never divide by it — a
    /// detector that returns nonsense must degrade to a useless grid, not to infinities that
    /// propagate into every tick position.
    let bpm: Double
    /// Where the first downbeat falls, in seconds from the start of the clip.
    let downbeatOffsetSeconds: Double
    let beatsPerBar: Int

    init(bpm: Double, downbeatOffsetSeconds: Double, beatsPerBar: Int = 4) {
        self.bpm = min(max(1, bpm.isFinite ? bpm : 120), 400)
        self.downbeatOffsetSeconds = downbeatOffsetSeconds.isFinite ? downbeatOffsetSeconds : 0
        self.beatsPerBar = max(1, beatsPerBar)
    }

    var beatDuration: Double { 60 / bpm }
    var barDuration: Double { beatDuration * Double(beatsPerBar) }

    /// How much floating-point slack, measured in beats, every flooring and ceiling in this type
    /// allows before it decides a time is past a beat boundary.
    ///
    /// Without it the round trip is not exact. `beatDuration` is `60 / bpm`, which is only exactly
    /// representable for a handful of tempi (120 BPM is one, which is why every 120 BPM fixture in
    /// the suite was blind to this), so `(time(beatIndex: i) - downbeatOffsetSeconds) /
    /// beatDuration` regularly evaluates to `i - ε` and floors to `i - 1`. At the detector's own
    /// output — 126.048… BPM, offset 0.7314… s — that mislabels 4 of the first 40 beats, which the
    /// ruler draws as two adjacent full-height ticks both numbered "1" with bar lines missing
    /// elsewhere.
    ///
    /// 1e-9 beats is under a nanosecond at any tempo this grid accepts, so it can never absorb a
    /// real time difference; and it is far larger than the accumulated error, whose worst case is
    /// a few ulps of the quotient (~1.5e-11 beats even at 400 BPM three hours into a clip).
    private static let beatEpsilon = 1e-9

    /// Fractional beat position relative to the first downbeat: 0 at the downbeat, negative before.
    private func rawBeatPosition(at time: Double) -> Double {
        (time - downbeatOffsetSeconds) / beatDuration
    }

    /// Beat index relative to the first downbeat: 0 at the downbeat, negative before it.
    private func beatIndex(at time: Double) -> Int {
        Int((rawBeatPosition(at: time) + Self.beatEpsilon).rounded(.down))
    }

    func time(beatIndex index: Int) -> Double {
        downbeatOffsetSeconds + Double(index) * beatDuration
    }

    func position(at time: Double) -> Position {
        let index = beatIndex(at: time)
        // Floored division, so the bar keeps counting down through negative indices instead of
        // truncating toward zero and repeating bar 0 on both sides of the downbeat.
        let bar = Int((Double(index) / Double(beatsPerBar)).rounded(.down)) + 1
        var beat = index % beatsPerBar
        if beat < 0 { beat += beatsPerBar }
        return Position(bar: bar, beat: beat + 1)
    }

    func time(bar: Int, beat: Int) -> Double {
        time(beatIndex: (bar - 1) * beatsPerBar + (beat - 1))
    }

    /// The beat indices whose times fall inside the range, or `nil` when none do.
    ///
    /// Both range generators go through this so they cannot disagree about which beats exist, and
    /// so `downbeatTimes` never has to re-derive a beat number from a time it just produced.
    private func beatIndices(from start: Double, to end: Double) -> ClosedRange<Int>? {
        guard end > start, beatDuration > 0 else { return nil }
        // The same epsilon as `beatIndex(at:)`, in the direction each end rounds: a `start` that is
        // itself a beat must be included rather than rounded up past itself, and likewise an `end`.
        let first = Int((rawBeatPosition(at: start) - Self.beatEpsilon).rounded(.up))
        let last = Int((rawBeatPosition(at: end) + Self.beatEpsilon).rounded(.down))
        guard last >= first else { return nil }
        return first...last
    }

    func beatTimes(from start: Double, to end: Double) -> [Double] {
        guard let indices = beatIndices(from: start, to: end) else { return [] }
        return indices.map(time(beatIndex:))
    }

    /// Filtered on the beat index directly rather than by round-tripping each generated time back
    /// through `position(at:)`. Belt and braces with the epsilon in `beatIndex(at:)`: even if a
    /// future change to the arithmetic reintroduced a rounding error, a downbeat here is one by
    /// construction — `index` is a multiple of `beatsPerBar` — rather than by measurement.
    func downbeatTimes(from start: Double, to end: Double) -> [Double] {
        guard let indices = beatIndices(from: start, to: end) else { return [] }
        return indices.filter { $0 % beatsPerBar == 0 }.map(time(beatIndex:))
    }

    /// The closest beat, not the preceding one — loop edges snap to whichever side is nearer.
    func nearestBeat(to time: Double) -> Double {
        let index = ((time - downbeatOffsetSeconds) / beatDuration).rounded()
        return downbeatOffsetSeconds + index * beatDuration
    }
}
