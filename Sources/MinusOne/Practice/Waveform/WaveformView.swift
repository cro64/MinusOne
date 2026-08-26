import AppKit

/// The sidebar's 18pt clip thumbnail: peak bars, with the not-yet-separated tail in a dimmer
/// colour.
///
/// Thumbnail only. The deck's interactive waveform is `DeckTimelineView` now, and the two used to
/// disagree about geometry — bars stepped by index while the playhead and loop used a fraction of
/// the width (spec §14). One geometry, shared with the timeline through `TimelineMetrics`.
final class WaveformView: NSView {
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    /// Fraction (0...1) of the clip that has finished separation.
    var readyFraction: CGFloat = 1 { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The columns actually drawn, binned down from `peaks` to the number of bars that fit.
    ///
    /// The old code drew one bar per stored column with `barWidth = max(1, bounds.width / count)`:
    /// at the sidebar's 200–340pt with 600 stored columns that clamps to 1 and each bar overdraws
    /// its two neighbours, which is why the thumbnail rendered as a solid block.
    func renderedColumns() -> [PeakColumn] {
        let sourceCount = peaks.count / 2
        let targetCount = TimelineMetrics.barCount(forWidth: bounds.width)
        guard sourceCount > 0, targetCount > 0 else { return [] }
        return PeakBinning.rebin(targetCount: targetCount, sourceCount: sourceCount) { index in
            PeakColumn(minimum: peaks[index * 2], maximum: peaks[index * 2 + 1], rms: 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let columns = renderedColumns()
        guard !columns.isEmpty else { return }

        let midY = bounds.height / 2
        let readyColumns = Int(CGFloat(columns.count) * readyFraction)
        // Whole device pixels, so bars land on pixel boundaries instead of being antialiased
        // across two — the other half of why the old thumbnail looked like mush.
        let scale = window?.backingScaleFactor ?? 2

        for (index, column) in columns.enumerated() {
            let topY = midY - CGFloat(column.maximum) * midY
            let bottomY = midY - CGFloat(column.minimum) * midY
            let x = TimelineMetrics.devicePixelAligned(CGFloat(index) * TimelineMetrics.barStep, scale: scale)
            let color: NSColor = index < readyColumns
                ? .secondaryLabelColor
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
            color.setFill()
            NSRect(
                x: x,
                y: min(topY, bottomY),
                width: TimelineMetrics.barWidth,
                height: max(1, abs(bottomY - topY))
            ).fill()
        }
    }
}
