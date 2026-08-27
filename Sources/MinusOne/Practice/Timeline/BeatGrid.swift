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

    /// Beat index relative to the first downbeat: 0 at the downbeat, negative before it.
    private func beatIndex(at time: Double) -> Int {
        Int(((time - downbeatOffsetSeconds) / beatDuration).rounded(.down))
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

    func beatTimes(from start: Double, to end: Double) -> [Double] {
        guard end > start, beatDuration > 0 else { return [] }
        let first = Int((((start - downbeatOffsetSeconds) / beatDuration)).rounded(.up))
        let last = Int((((end - downbeatOffsetSeconds) / beatDuration)).rounded(.down))
        guard last >= first else { return [] }
        return (first...last).map(time(beatIndex:))
    }

    func downbeatTimes(from start: Double, to end: Double) -> [Double] {
        beatTimes(from: start, to: end).filter { position(at: $0).beat == 1 }
    }

    /// The closest beat, not the preceding one — loop edges snap to whichever side is nearer.
    func nearestBeat(to time: Double) -> Double {
        let index = ((time - downbeatOffsetSeconds) / beatDuration).rounded()
        return downbeatOffsetSeconds + index * beatDuration
    }
}
