import CoreGraphics

/// The single source of truth for converting between clip time and horizontal position.
///
/// Every timeline view reads a `Viewport` and none performs its own time↔x arithmetic. That rule
/// is what keeps four sibling stem lanes from drifting a pixel apart from one another — the
/// specific failure mode a stacked-lane layout invites.
struct Viewport: Equatable {
    /// Length of the whole clip, in seconds. Always > 0 so the arithmetic can't divide by zero.
    let clipDuration: Double
    /// Shortest span the viewport may show — the maximum-zoom limit. There is no point zooming
    /// past the stored peak resolution, so the caller sets this from the sidecar's column rate.
    let minVisibleDuration: Double
    /// Width of the lane canvas, in points.
    var widthPoints: CGFloat

    private(set) var startTime: Double
    private(set) var visibleDuration: Double

    init(clipDuration: Double, widthPoints: CGFloat, minVisibleDuration: Double = 0.5) {
        let duration = max(0.001, clipDuration)
        self.clipDuration = duration
        self.minVisibleDuration = min(max(0.001, minVisibleDuration), duration)
        self.widthPoints = widthPoints
        self.startTime = 0
        self.visibleDuration = duration
    }

    var endTime: Double { startTime + visibleDuration }

    var pixelsPerSecond: CGFloat { widthPoints / CGFloat(visibleDuration) }

    func x(forTime time: Double) -> CGFloat {
        CGFloat(time - startTime) * pixelsPerSecond
    }

    func time(forX x: CGFloat) -> Double {
        startTime + Double(x / max(widthPoints, 1)) * visibleDuration
    }

    /// Zooms so the instant currently under `anchorX` stays under `anchorX`. `factor > 1` zooms in.
    /// At the clip's edges the clamp wins and the anchor does shift — that is correct, and why the
    /// anchoring test uses a mid-clip pointer.
    func zoomed(by factor: Double, around anchorX: CGFloat) -> Viewport {
        guard factor > 0 else { return self }
        let anchorTime = time(forX: anchorX)
        let anchorFraction = Double(anchorX / max(widthPoints, 1))
        var next = self
        next.visibleDuration = min(max(visibleDuration / factor, minVisibleDuration), clipDuration)
        next.startTime = anchorTime - anchorFraction * next.visibleDuration
        return next.clamped()
    }

    /// Pans by a content drag: positive `dx` drags the waveform to the right, which moves the
    /// view *backward* in time.
    ///
    /// This direction is chosen to match the event that will drive it. A trackpad drag to the
    /// right reports a positive `scrollingDeltaX`, and dragging the waveform right should reveal
    /// earlier audio — so the call site can pass the delta through untouched instead of
    /// remembering to negate it.
    func panned(byPoints dx: CGFloat) -> Viewport {
        var next = self
        next.startTime = startTime - Double(dx / max(widthPoints, 1)) * visibleDuration
        return next.clamped()
    }

    func clamped() -> Viewport {
        var next = self
        next.visibleDuration = min(max(visibleDuration, minVisibleDuration), clipDuration)
        next.startTime = min(max(0, startTime), clipDuration - next.visibleDuration)
        return next
    }
}
