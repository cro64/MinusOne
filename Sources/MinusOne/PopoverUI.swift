import AppKit

extension NSColor {
    /// Brand coral, `#E8475A` (`srgb 0.910, 0.278, 0.353`). Replaces `.controlAccentColor`
    /// app-wide per the design system in REDESIGN.md §6.
    static let brandAccent = NSColor(srgbRed: 0.910, green: 0.278, blue: 0.353, alpha: 1.0)

    /// Deepened accent, `#A93347` (`srgb 0.663, 0.200, 0.278`), for small-scale legibility —
    /// status text and small dots/indicators, where the full-saturation coral is harder to read
    /// at small sizes. `brandAccent` stays reserved for large fills (buttons, icon fills, slider
    /// tracks).
    static let brandAccentDeep = NSColor(srgbRed: 0.663, green: 0.200, blue: 0.278, alpha: 1.0)

    /// Amber `#D98C3F` — Drums identity color, REDESIGN.md §4/§6 stem palette.
    static let stemDrums = NSColor(srgbRed: 0.851, green: 0.549, blue: 0.247, alpha: 1.0)
    /// Teal `#3F8FA8` — Bass identity color.
    static let stemBass = NSColor(srgbRed: 0.247, green: 0.561, blue: 0.659, alpha: 1.0)
    /// Plum `#8A6FB0` — Other identity color.
    static let stemOther = NSColor(srgbRed: 0.541, green: 0.435, blue: 0.690, alpha: 1.0)
}

extension SeparationStem {
    /// Fixed per-stem identity color (REDESIGN.md §4), reused for the mixer row, slider fill,
    /// and label everywhere a stem is represented. Vocals deliberately reuses the brand accent.
    var identityColor: NSColor {
        switch self {
        case .vocals: return .brandAccent
        case .drums: return .stemDrums
        case .bass: return .stemBass
        case .other: return .stemOther
        }
    }
}

/// Shared layout and control styling for both the menu bar popover (compact scale) and the
/// desktop window (regular scale). Formerly popover-only; now the design-system source of truth.
enum PopoverUI {
    enum Metrics {
        /// Inset around menu content.
        static let padding: CGFloat = 15
        static let sectionSpacing: CGFloat = 10
        static let rowSpacing: CGFloat = 6
        static let rowHeight: CGFloat = 20
        static let labelWidth: CGFloat = 58
        static let cornerRadius: CGFloat = 8
        /// Usable track length for Intensity / Gain (also drives menu width).
        static let sliderMinWidth: CGFloat = 88
        /// Row content: label + gap + control.
        static var contentWidth: CGFloat { labelWidth + 8 + sliderMinWidth }
        static var menuWidth: CGFloat { contentWidth + padding * 2 }

        static func menuSize(contentHeight: CGFloat) -> NSSize {
            NSSize(
                width: menuWidth,
                height: ceil(contentHeight) + padding * 2
            )
        }

        /// Window-scale metrics (desktop window content, e.g. the Practice tab), as opposed to
        /// the compact metrics above which size the menu bar popover. Both read from this one
        /// source per REDESIGN.md §6 rather than each surface inventing its own numbers.
        enum Regular {
            static let padding: CGFloat = 24
            static let sectionSpacing: CGFloat = 16
            static let rowSpacing: CGFloat = 10
            static let labelWidth: CGFloat = 64
        }
    }

    /// Clear root that owns the soft shadow; rounded vibrancy lives in the returned effect view.
    static func makeMenuRoot(size: NSSize) -> (root: NSView, effect: NSVisualEffectView) {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.masksToBounds = false
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.28
        root.layer?.shadowRadius = 18
        root.layer?.shadowOffset = .zero
        updateShadowPath(for: root, size: size)

        let effect = makeEffectView(size: size)
        effect.autoresizingMask = [.width, .height]
        root.addSubview(effect)
        return (root, effect)
    }

    static func updateShadowPath(for root: NSView, size: NSSize) {
        root.layer?.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerWidth: Metrics.cornerRadius,
            cornerHeight: Metrics.cornerRadius,
            transform: nil
        )
    }

    static func makeEffectView(size: NSSize) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.cornerRadius = Metrics.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    static func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    static func valueLabel(initialValue: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: initialValue)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.drawsBackground = true
        label.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }

    static func configurePopUp(_ popUp: NSPopUpButton) {
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.systemFontSize)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    static func configureSlider(_ slider: NSSlider) {
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.sliderMinWidth).isActive = true
    }

    static func formRow(label: String, control: NSView) -> NSView {
        let title = fieldLabel(label)
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: Metrics.labelWidth),
            row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight)
        ])
        return row
    }

    static func sliderRow(label: String, slider: NSSlider) -> NSView {
        formRow(label: label, control: slider)
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    static func linkButton(title: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.contentTintColor = .brandAccent
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func accessoryButton(title: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .accessoryBar
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Shared style for window-scale toolbar actions (Practice tab's Import/Record) so both use
    /// one button language instead of mixing a plain toolbar item with a custom-styled button.
    static func toolbarActionButton(title: String, symbolName: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        return button
    }

    /// Shared style for compact toggle/transport controls (Practice deck's Play/Loop/Solo/Mute)
    /// in place of stock `NSButton` bezels — pill-shaped, accent-tinted when engaged.
    static func toggleControlButton(title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        return button
    }

    static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func pinContent(_ content: NSView, in container: NSView) {
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.padding),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.padding),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.padding),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metrics.padding)
        ])
    }
}

/// Status row: title only. For errors, an info button shows the message on click.
final class StatusHeaderView: NSView {
    private let dot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let infoButton = NSButton(title: "", target: nil, action: nil)
    private var errorDetail: String?
    private var infoPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Error details")?
            .withSymbolConfiguration(config)
        infoButton.imagePosition = .imageOnly
        infoButton.isBordered = false
        infoButton.bezelStyle = .inline
        infoButton.contentTintColor = .secondaryLabelColor
        infoButton.target = self
        infoButton.action = #selector(showErrorInfo)
        infoButton.isHidden = true
        infoButton.setContentHuggingPriority(.required, for: .horizontal)
        infoButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(titleField)
        addSubview(infoButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PopoverUI.Metrics.rowHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            titleField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoButton.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
            infoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 16),
            infoButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, indicatorColor: NSColor, errorDetail: String? = nil) {
        infoPopover?.performClose(nil)
        infoPopover = nil

        titleField.stringValue = title
        titleField.textColor = indicatorColor == .brandAccentDeep ? .brandAccentDeep : .labelColor
        dot.layer?.backgroundColor = indicatorColor.cgColor

        let detail = errorDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.errorDetail = (detail?.isEmpty == false) ? detail : nil
        infoButton.isHidden = self.errorDetail == nil
        infoButton.toolTip = self.errorDetail
    }

    @objc private func showErrorInfo() {
        guard let detail = errorDetail else { return }
        if let existing = infoPopover, existing.isShown {
            existing.performClose(nil)
            return
        }

        let label = NSTextField(wrappingLabelWithString: detail)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 200

        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        let controller = NSViewController()
        controller.view = container
        container.layoutSubtreeIfNeeded()
        controller.preferredContentSize = NSSize(
            width: 220,
            height: ceil(label.fittingSize.height + 16)
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        infoPopover = popover
        popover.show(relativeTo: infoButton.bounds, of: infoButton, preferredEdge: .maxY)
    }
}

/// Slider that reports drag begin/end so callers can show a transient value overlay.
final class DragValueSlider: NSSlider {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
        defer { onDragEnded?() }
        super.mouseDown(with: event)
    }
}
