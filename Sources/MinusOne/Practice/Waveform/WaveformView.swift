import AppKit

/// Draws a waveform from precomputed min/max peak pairs, distinguishing the "ready" (separated,
/// playable) region from the "still processing" tail. Supports tap-to-seek and drag-to-set-loop
/// in the interactive (non-thumbnail) style.
final class WaveformView: NSView {
    enum Style {
        case thumbnail
        case interactive
    }

    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    /// Fraction (0...1) of the clip that has finished separation and is playable.
    var readyFraction: CGFloat = 1 { didSet { needsDisplay = true } }
    var playheadFraction: CGFloat? { didSet { needsDisplay = true } }
    var loopRange: ClosedRange<CGFloat>? { didSet { needsDisplay = true } }

    var onSeek: ((CGFloat) -> Void)?
    var onLoopRangeChanged: ((ClosedRange<CGFloat>) -> Void)?

    private let style: Style
    private var dragStartFraction: CGFloat?

    /// Bar geometry, shared with the timeline lanes in Phase 2.
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1

    /// The columns actually drawn, binned down from `peaks` to the number of bars that fit.
    ///
    /// Split out from `draw(_:)` so the binning can be asserted directly. The old code drew one
    /// bar per stored column with `barWidth = max(1, bounds.width / columnCount)`: at the sidebar's
    /// 200–340pt with 600 stored columns that clamps to 1 and each bar overdraws its two
    /// neighbours, which is why the thumbnail rendered as a solid block.
    func renderedColumns() -> [PeakColumn] {
        let sourceCount = peaks.count / 2
        let targetCount = Int(bounds.width / (Self.barWidth + Self.barGap))
        guard sourceCount > 0, targetCount > 0 else { return [] }
        return PeakBinning.rebin(targetCount: targetCount, sourceCount: sourceCount) { index in
            PeakColumn(minimum: peaks[index * 2], maximum: peaks[index * 2 + 1], rms: 0)
        }
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// `draw(_:)` strokes with `labelColor`, which inverts between appearances.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        context.clear(bounds)

        guard !peaks.isEmpty else { return }
        let columns = renderedColumns()
        guard !columns.isEmpty else { return }

        if let loopRange {
            let loopRect = NSRect(
                x: bounds.width * loopRange.lowerBound,
                y: 0,
                width: bounds.width * (loopRange.upperBound - loopRange.lowerBound),
                height: bounds.height
            )
            NSColor.brandAccent.withAlphaComponent(0.14).setFill()
            loopRect.fill()
        }

        let midY = bounds.height / 2
        let step = Self.barWidth + Self.barGap
        let readyColumns = Int(CGFloat(columns.count) * readyFraction)
        // Whole device pixels, so bars land on pixel boundaries instead of being antialiased
        // across two — the other half of why the old thumbnail looked like mush.
        let scale = window?.backingScaleFactor ?? 2

        for (index, column) in columns.enumerated() {
            let topY = midY - CGFloat(column.maximum) * midY
            let bottomY = midY - CGFloat(column.minimum) * midY
            let x = (CGFloat(index) * step * scale).rounded() / scale
            let rect = NSRect(
                x: x,
                y: min(topY, bottomY),
                width: Self.barWidth,
                height: max(1, abs(bottomY - topY))
            )

            let color: NSColor = index < readyColumns
                ? (style == .thumbnail ? NSColor.secondaryLabelColor : NSColor.brandAccent)
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
            color.setFill()
            rect.fill()
        }

        if style == .interactive, let playheadFraction {
            let x = bounds.width * playheadFraction
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
        }
    }

    // MARK: - Interaction (interactive style only)

    override func mouseDown(with event: NSEvent) {
        guard style == .interactive, bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragStartFraction = clampedFraction(for: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard style == .interactive, let start = dragStartFraction, bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let end = clampedFraction(for: point.x)
        let range = min(start, end)...max(start, end)
        loopRange = range
    }

    override func mouseUp(with event: NSEvent) {
        guard style == .interactive, let start = dragStartFraction, bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let end = clampedFraction(for: point.x)
        dragStartFraction = nil

        if abs(end - start) < 0.005 {
            // Treated as a tap, not a drag: seek if within the ready (playable) region.
            if end <= readyFraction {
                onSeek?(end)
            }
        } else {
            let range = min(start, end)...max(start, end)
            loopRange = range
            onLoopRangeChanged?(range)
        }
    }

    private func clampedFraction(for x: CGFloat) -> CGFloat {
        min(1, max(0, x / bounds.width))
    }
}
