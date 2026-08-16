import AppKit

/// Practice deck's empty state (REDESIGN.md §4): the logo's waveform mark over a short prompt.
///
/// This used to carry its own Import / Record buttons duplicating the action row above the clip
/// list. Two live copies of the same pair, a few hundred points apart, read as two different
/// features rather than one — so the buttons live in exactly one place now, and the subtitle
/// points at them.
final class PracticeEmptyStateView: NSView {
    override init(frame frameRect: NSRect) {
        // Template mask + `contentTintColor`, the same treatment `MenuBarController` gives the
        // idle menu bar glyph — *not* `waveform(color: .tertiaryLabelColor)`. A dynamic color drawn
        // into an `NSImage` is resolved once and baked into the bitmap, so the mark kept whichever
        // appearance was current when the deck was built and then disappeared against the opposite
        // background. `contentTintColor` holds the `NSColor` itself and re-resolves on its own.
        let markImage = MinusOneIcon.waveform(size: 56, color: .black, isActive: false)
        markImage.isTemplate = true
        let mark = NSImageView(image: markImage)
        mark.contentTintColor = .tertiaryLabelColor
        mark.constrainSize(width: 56, height: 56)

        let title = NSTextField(labelWithString: "No clip selected")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Import a clip or record system audio to start practicing.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping

        let stack = Layout.verticalStack([mark, title, subtitle], spacing: WindowUI.Metrics.rowSpacing)
        stack.alignment = .centerX
        stack.setCustomSpacing(WindowUI.Metrics.sectionSpacing, after: mark)
        stack.setCustomSpacing(4, after: title)

        super.init(frame: frameRect)

        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        Layout.pin(stack, to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
