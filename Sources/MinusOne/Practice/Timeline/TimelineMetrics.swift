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
    /// Measured, not derived, by `WindowSizingTests.testTheDeckFitsTheMinimumWindowHeight`, which
    /// prints it: **497pt** against the 600pt floor, 103pt spare. That is the deck's vertical
    /// stack (title, status, timeline, and the unified control bar — see
    /// `PracticeDeckViewController.buildContent`) at 421pt, of which
    /// `DeckTimelineView.height(forLaneCount: 4)` is 342 (22 ruler + 4 + 300 lanes + 4 + 12
    /// indicator), plus 24pt of window padding and the 52pt header strip.
    ///
    /// The BPM/Tap toolbar no longer has a row of its own: it is one of the arranged views inside
    /// the control bar alongside the transport and the speed slider, so there is no separate
    /// toolbar-row height to account for here any more (see `toolbarHeight`'s comment). If a
    /// later change lowers the window floor or grows the chrome past this margin, the
    /// compress-then-scroll behaviour is what to build then.
    static let laneHeight: CGFloat = 72
    static let laneSpacing: CGFloat = 4

    /// Width of a lane's header — name, fader, mute, solo, export. Spec §8's window arithmetic is
    /// built on this number.
    static let headerWidth: CGFloat = 132
    static let rulerHeight: CGFloat = 22

    /// The BPM/Tap toolbar's height. Spec §8 budgeted 38pt for it. It has no production call site
    /// any more: `TimelineToolbarView` is now one of the arranged views inside
    /// `PracticeDeckViewController`'s unified control bar, which sizes it by its own fitting size
    /// rather than by this constant. It stays here as the fitting-height budget
    /// `TimelineToolbarTests` checks the view against in isolation, and alongside the rest of the
    /// timeline's shared geometry since that is where it originated.
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
