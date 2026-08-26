import AppKit

/// The deck's timeline: a ruler, one lane per track, a playhead overlay and a scroll indicator,
/// all reading one `Viewport`.
///
/// This class is the **only** writer of viewport state. Children read it and draw; none of them
/// converts a time to a pixel on its own. That rule is what keeps four sibling lanes from drifting
/// apart, and it is the specific thing to check in review (spec §11, risk 1).
///
/// Layout is explicit frames in `layout()`, not Auto Layout. The canvas column's origin and width
/// feed the viewport directly, and a constraint solver is the wrong instrument for geometry that
/// is computed from time.
final class DeckTimelineView: NSView {
    var onSeek: ((Double) -> Void)?
    var onLoopRangeChanged: ((ClosedRange<Double>) -> Void)?
    var onStemVolumeChanged: ((SeparationStem, Float) -> Void)?
    var onStemMuteToggled: ((SeparationStem, Bool) -> Void)?
    var onStemSoloToggled: ((SeparationStem) -> Void)?
    var onStemExportRequested: ((SeparationStem) -> Void)?

    private(set) var viewport: Viewport
    private(set) var tracks: [PeakTrack] = []

    /// How much of the clip is playable. Separate from the peak data's own coverage: peaks may be
    /// written for audio the engine has not reloaded yet, and a seek into that region would be a
    /// seek into silence.
    var readyDuration: Double = 0

    var loopRange: ClosedRange<Double>? {
        get { overlay.loopRange }
        set { overlay.loopRange = newValue }
    }

    private var peakStore: PeakStore?
    private var clipDuration: Double = 1

    private let ruler = TimelineRulerView()
    private let overlay = PlayheadOverlayView()
    private let indicator = TimelineScrollIndicatorView()
    private var lanes: [StemLaneView] = []
    private var headers: [SeparationStem: LaneHeaderView] = [:]
    private var headerViews: [NSView] = []

    private var dragStartX: CGFloat?
    private var loopBeforeDrag: ClosedRange<Double>?

    init() {
        viewport = Viewport(clipDuration: 1, widthPoints: 0)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ruler)
        addSubview(indicator)
        // Last, so it composites over the lanes. It returns `nil` from `hitTest`, so being on top
        // costs nothing in events.
        addSubview(overlay)

        indicator.onScrubToStartTime = { [weak self] time in
            guard let self else { return }
            self.apply(self.viewport.scrolled(toStartTime: time))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Ruler + lanes + indicator, with `laneSpacing` between every block.
    static func height(forLaneCount count: Int) -> CGFloat {
        let lanes = CGFloat(count) * TimelineMetrics.laneHeight + CGFloat(max(0, count - 1)) * TimelineMetrics.laneSpacing
        return TimelineMetrics.rulerHeight
            + TimelineMetrics.laneSpacing
            + lanes
            + TimelineMetrics.laneSpacing
            + TimelineMetrics.scrollIndicatorHeight
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(forLaneCount: max(1, tracks.count)))
    }

    // MARK: - Clip lifecycle

    func show(clipDuration: Double, peakStore: PeakStore) {
        self.clipDuration = max(0.001, clipDuration)
        self.peakStore = peakStore
        rebuildLanes()
        viewport = makeViewport(startingFrom: nil)
        propagateViewport()
        needsLayout = true
    }

    /// Separation has appended to the sidecars. The lane set may grow; the viewport must not move
    /// — spec §7: following the ready edge would yank the view away from whatever the user was
    /// studying.
    func refreshPeaks() {
        guard let peakStore else { return }
        peakStore.reload()
        if desiredTracks() != tracks {
            rebuildLanes()
            needsLayout = true
        }
        for lane in lanes { lane.invalidatePeaks() }
        propagateViewport()
    }

    func setPlayheadTime(_ time: Double) {
        overlay.playheadTime = time
    }

    func setSoloedStem(_ stem: SeparationStem?) {
        for (candidate, header) in headers {
            header.setSoloed(candidate == stem)
        }
    }

    func setExportEnabled(_ enabled: Bool) {
        for header in headers.values { header.setExportEnabled(enabled) }
    }

    // MARK: - Viewport

    /// Maximum zoom is 1:1 with the stored peaks: one drawn bar per stored column. There is
    /// nothing finer on disk, so zooming past it would only interpolate (spec §4).
    private func makeViewport(startingFrom previous: Viewport?) -> Viewport {
        let width = canvasWidth
        let bars = max(1, TimelineMetrics.barCount(forWidth: width))
        let columnsPerSecond = peakStore?.storedColumnsPerSecond ?? (44_100.0 / 256.0)
        let minimum = Double(bars) / max(1, columnsPerSecond)
        guard let previous else {
            return Viewport(clipDuration: clipDuration, widthPoints: width, minVisibleDuration: minimum)
        }
        return previous.resized(toWidth: width, minVisibleDuration: minimum)
    }

    /// The single write point. Everything that changes the viewport goes through here.
    func apply(_ next: Viewport) {
        guard next != viewport else { return }
        viewport = next
        propagateViewport()
    }

    private func propagateViewport() {
        ruler.viewport = viewport
        overlay.viewport = viewport
        indicator.viewport = viewport
        for lane in lanes { lane.viewport = viewport }
    }

    // MARK: - Lanes

    /// Four stem lanes once any stem has peaks; a single mix lane before that.
    ///
    /// All four, not just the ones with sidecars: separation writes the four stem *audio* files
    /// together, and `OfflineSeparationEngine` catches sidecar-writer failures per stem — so a stem
    /// can be fully playable while missing only its peaks. The lane header is the only place that
    /// stem's fader, mute, solo and export live, so dropping its lane would make a playable stem
    /// unreachable. Without peaks it simply draws as the unseparated tail until backfill supplies
    /// them.
    ///
    /// Spec §9: a clip whose separation never ran still gets a deck — one mix lane, because four
    /// empty lanes would claim stems that genuinely do not exist.
    private func desiredTracks() -> [PeakTrack] {
        guard let peakStore else { return [.mix] }
        let anyStemHasPeaks = SeparationStem.allCases.contains { peakStore.hasTrack(.stem($0)) }
        return anyStemHasPeaks ? SeparationStem.allCases.map(PeakTrack.stem) : [.mix]
    }

    private func rebuildLanes() {
        for lane in lanes { lane.removeFromSuperview() }
        for header in headerViews { header.removeFromSuperview() }
        lanes.removeAll()
        headers.removeAll()
        headerViews.removeAll()

        guard let peakStore else { return }
        tracks = desiredTracks()

        for track in tracks {
            let lane = StemLaneView(track: track, peakStore: peakStore)
            lanes.append(lane)
            addSubview(lane, positioned: .below, relativeTo: overlay)

            guard case .stem(let stem) = track else { continue }
            let header = LaneHeaderView(stem: stem)
            header.translatesAutoresizingMaskIntoConstraints = true
            header.onVolumeChanged = { [weak self] in self?.onStemVolumeChanged?(stem, $0) }
            header.onMuteToggled = { [weak self] in self?.onStemMuteToggled?(stem, $0) }
            header.onSoloToggled = { [weak self] in self?.onStemSoloToggled?(stem) }
            header.onExportRequested = { [weak self] in self?.onStemExportRequested?(stem) }
            headers[stem] = header
            headerViews.append(header)
            addSubview(header)
        }
        invalidateIntrinsicContentSize()
    }

    // MARK: - Layout

    private var canvasWidth: CGFloat {
        max(0, bounds.width - TimelineMetrics.headerWidth)
    }

    override func layout() {
        super.layout()
        let canvasX = TimelineMetrics.headerWidth
        let width = canvasWidth

        ruler.frame = NSRect(x: canvasX, y: 0, width: width, height: TimelineMetrics.rulerHeight)

        var y = TimelineMetrics.rulerHeight + TimelineMetrics.laneSpacing
        for (index, lane) in lanes.enumerated() {
            lane.frame = NSRect(x: canvasX, y: y, width: width, height: TimelineMetrics.laneHeight)
            if index < headerViews.count {
                headerViews[index].frame = NSRect(x: 0, y: y, width: TimelineMetrics.headerWidth, height: TimelineMetrics.laneHeight)
            }
            y += TimelineMetrics.laneHeight + TimelineMetrics.laneSpacing
        }

        // From the top of the ruler to the bottom of the last lane: one band, all four lanes, so
        // the loop cannot read as lane-local state.
        overlay.frame = NSRect(x: canvasX, y: 0, width: width, height: max(0, y - TimelineMetrics.laneSpacing))
        indicator.frame = NSRect(x: canvasX, y: y, width: width, height: TimelineMetrics.scrollIndicatorHeight)

        // A resize changes pixels per second, never the visible seconds.
        apply(makeViewport(startingFrom: viewport))
    }

    // MARK: - Gestures

    /// Where a window point falls on the canvas, or `nil` if it is over the lane headers. The
    /// headers hold live controls; a scroll or a click there is theirs, not the timeline's.
    func canvasX(forWindowPoint point: NSPoint) -> CGFloat? {
        let local = convert(point, from: nil)
        let x = local.x - TimelineMetrics.headerWidth
        return x >= 0 ? x : nil
    }

    func pan(byPoints dx: CGFloat) {
        apply(viewport.panned(byPoints: dx))
    }

    /// Zoom anchored at a canvas x, so the instant under the pointer stays put (spec §7).
    func zoom(by factor: Double, aroundX canvasX: CGFloat) {
        apply(viewport.zoomed(by: factor, around: canvasX))
    }

    func setHover(atX x: CGFloat?) {
        overlay.hoverTime = x.map { viewport.time(forX: $0) }
    }

    // MARK: - Click, drag, loop

    /// A movement under this many points is a tap, not a drag. Points rather than a fraction of
    /// the clip: at a deep zoom a fractional threshold would make every click a loop.
    private static let dragThreshold: CGFloat = 3

    func beginCanvasDrag(atX x: CGFloat) {
        dragStartX = x
        loopBeforeDrag = overlay.loopRange
    }

    func continueCanvasDrag(toX x: CGFloat) {
        guard let dragStartX, abs(x - dragStartX) >= Self.dragThreshold else { return }
        // Previewed, not committed: the engine hears about it once, on mouse up.
        overlay.loopRange = range(from: dragStartX, to: x)
    }

    func endCanvasDrag(atX x: CGFloat) {
        guard let start = dragStartX else { return }
        dragStartX = nil

        guard abs(x - start) >= Self.dragThreshold else {
            // A tap. Roll the preview back — a click must not destroy the loop the user drew.
            overlay.loopRange = loopBeforeDrag
            let time = viewport.time(forX: x)
            if time <= readyDuration { onSeek?(time) }
            return
        }
        let loop = range(from: start, to: x)
        overlay.loopRange = loop
        onLoopRangeChanged?(loop)
    }

    private func range(from startX: CGFloat, to endX: CGFloat) -> ClosedRange<Double> {
        let a = viewport.time(forX: min(startX, endX))
        let b = viewport.time(forX: max(startX, endX))
        return min(a, b)...max(a, b)
    }

    // MARK: - Events

    override func scrollWheel(with event: NSEvent) {
        guard let x = canvasX(forWindowPoint: event.locationInWindow) else {
            super.scrollWheel(with: event)
            return
        }
        if event.modifierFlags.contains(.command) {
            // Exponential so each notch is the same proportional step whatever the current zoom.
            zoom(by: pow(1.01, Double(event.scrollingDeltaY)), aroundX: x)
        } else {
            // Passed through unnegated: `panned(byPoints:)` is documented to take a content drag,
            // and a trackpad swipe right reports a positive `scrollingDeltaX`.
            pan(byPoints: event.scrollingDeltaX)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let x = canvasX(forWindowPoint: event.locationInWindow) else { return }
        zoom(by: 1 + Double(event.magnification), aroundX: x)
    }

    override func mouseDown(with event: NSEvent) {
        guard let x = canvasX(forWindowPoint: event.locationInWindow) else { return }
        beginCanvasDrag(atX: x)
    }

    override func mouseDragged(with event: NSEvent) {
        // Not gated on the canvas column: a drag that starts on a lane and wanders over the
        // headers is still that drag.
        continueCanvasDrag(toX: convert(event.locationInWindow, from: nil).x - TimelineMetrics.headerWidth)
    }

    override func mouseUp(with event: NSEvent) {
        endCanvasDrag(atX: convert(event.locationInWindow, from: nil).x - TimelineMetrics.headerWidth)
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(atX: canvasX(forWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(atX: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Test seams

    var canvasFramesForTesting: [NSRect] { [ruler.frame] + lanes.map(\.frame) + [overlay.frame, indicator.frame] }
    var childViewportsForTesting: [Viewport] { [ruler.viewport, overlay.viewport, indicator.viewport] + lanes.map(\.viewport) }
    var laneRenderCountsForTesting: [Int] { lanes.map(\.renderCount) }
    var hoverTimeForTesting: Double? { overlay.hoverTime }
}
