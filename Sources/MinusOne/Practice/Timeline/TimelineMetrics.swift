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
    /// is deliberately not built, because it is unreachable — the deck fits inside
    /// `WindowSizing.minimum`'s 600pt with room to spare.
    ///
    /// Measured, not derived, by `WindowSizingTests.testTheDeckFitsTheMinimumWindowHeight`, which prints
    /// it: **578pt** against the 600pt floor, 22pt spare. That is the deck's vertical stack at
    /// 502pt (of which `DeckTimelineView.height(forLaneCount: 4)` is 342: 22 ruler + 4 + 300 lanes
    /// + 4 + 12 indicator) plus 24pt of window padding and the 52pt header strip.
    ///
    /// The BPM/Tap toolbar used to live inside that 384pt figure; it now sits in
    /// `PracticeDeckViewController`'s content stack as its own row (temporarily — see
    /// `toolbarHeight`'s comment), which is why the stack total moved from 490pt to 502pt while
    /// the timeline's own height shrank. If a later change lowers the window floor or grows the
    /// chrome past this margin, the compress-then-scroll behaviour is what to build then.
    static let laneHeight: CGFloat = 72
    static let laneSpacing: CGFloat = 4

    /// Width of a lane's header — name, fader, mute, solo, export. Spec §8's window arithmetic is
    /// built on this number.
    static let headerWidth: CGFloat = 132
    static let rulerHeight: CGFloat = 22

    /// The BPM/Tap toolbar's height. Spec §8 budgeted 38pt for it. It no longer sits inside
    /// `DeckTimelineView` — it moved to `PracticeDeckViewController`'s content stack as its own
    /// row (temporary, until it is folded into the unified control bar) — but the row still needs
    /// this constant, so it stays here alongside the rest of the timeline's shared geometry.
    static let toolbarHeight: CGFloat = 38
    static let scrollIndicatorHeight: CGFloat = 12

    /// The peak envelope is drawn at this alpha with a solid RMS core inside it — Audacity's
    /// two-shade rendering, and per spec §5 the single largest legibility gain available.
    static let envelopeAlpha: CGFloat = 0.30

    static func barCount(forWidth width: CGFloat) -> Int {
        max(0, Int(width / barStep))
    }

    /// Snaps a viewport-derived x onto whole device pixels.
    ///
    /// Every timeline view draws on the same grid, so they share one implementation: a divergent
    /// fallback or rounding rule in any one of them would put its bars a fraction of a point off
    /// its siblings', which is the drift the `Viewport`-only rule exists to prevent. This is a
    /// post-hoc snap on an x that already came from the viewport — it is not a second geometry.
    static func devicePixelAligned(_ x: CGFloat, scale: CGFloat) -> CGFloat {
        (x * scale).rounded() / scale
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
