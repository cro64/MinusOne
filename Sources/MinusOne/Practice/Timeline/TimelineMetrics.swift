import CoreGraphics

/// Every shared geometry constant of the deck timeline, in one place.
///
/// One place rather than each view's own literals: the ruler, four lanes, the overlay and the
/// scroll indicator have to line up to the pixel, and a constant duplicated across six files is
/// how that stops being true.
enum TimelineMetrics {
    /// 2pt bar, 1pt gap — wide enough to survive rounding onto whole device pixels, which is the
    /// direct fix for the fractional-x antialiasing the old 600-column waveform suffered.
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1
    static var barStep: CGFloat { barWidth + barGap }

    /// Lane height. Spec §8 also names a 48pt floor with the stack scrolling below it; that path
    /// is deliberately not built, because it is unreachable: four 72pt lanes plus the ruler,
    /// indicator and deck chrome need 574pt, and `WindowSizing.minimum` is 600pt tall. If a later
    /// change lowers that floor, the compress-then-scroll behaviour is what to build then.
    static let laneHeight: CGFloat = 72
    static let laneSpacing: CGFloat = 4

    /// Width of a lane's header — name, fader, mute, solo, export. Spec §8's window arithmetic is
    /// built on this number.
    static let headerWidth: CGFloat = 132
    static let rulerHeight: CGFloat = 22
    static let scrollIndicatorHeight: CGFloat = 12

    /// The peak envelope is drawn at this alpha with a solid RMS core inside it — Audacity's
    /// two-shade rendering, and per spec §5 the single largest legibility gain available.
    static let envelopeAlpha: CGFloat = 0.30

    static func barCount(forWidth width: CGFloat) -> Int {
        max(0, Int(width / barStep))
    }
}

/// One drawn bar: where it goes, what instant it represents, and what it contains.
///
/// `x` and `time` both come from the `Viewport` — the view never derives one from the other.
struct TimelineBar: Equatable {
    let x: CGFloat
    let time: Double
    let column: PeakColumn
}
