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

    /// Approximates the Modernist design system's `--color-divider` token
    /// (`color-mix(in srgb, #201e1d 40%, transparent)`) with a dynamic system color instead of a
    /// literal fixed hex — `#201e1d` is near-black and would be effectively invisible against a
    /// dark-mode surface. `labelColor` already adapts per-appearance, so tinting its alpha keeps
    /// the "40%-strength foreground" relationship the token describes in both light and dark.
    static let flatDivider = NSColor.labelColor.withAlphaComponent(0.4)
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
        /// Inset around menu content. Values below are drawn from the Modernist token scale
        /// (`--space-1` … `--space-8`: 4/8/12/16/24/32), not hand-picked pixel counts.
        static let padding: CGFloat = 16 // space-4
        static let sectionSpacing: CGFloat = 12 // space-3
        static let rowSpacing: CGFloat = 8 // space-2
        static let rowHeight: CGFloat = 20
        /// Only "Live"/"Record" use this column at compact scale (Intensity/Gain moved to the
        /// window's Live tab) — composed from two scale tokens (space-6 + space-8) rather than
        /// the token set itself, since a label column width isn't one of the raw spacing values.
        static let labelWidth: CGFloat = 56
        /// The menu bar popover is the one surface that stays fully native macOS chrome (per
        /// design direction: native shape/materials there, flat/branded look reserved for the
        /// desktop window) — this rounding is only ever consumed by `makeMenuRoot`/`makeEffectView`.
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
            static let padding: CGFloat = 24 // space-6
            static let sectionSpacing: CGFloat = 16 // space-4
            static let rowSpacing: CGFloat = 8 // space-2
            /// Composed (space-8 + space-8), not a raw token — sized to fit "Intensity", the
            /// widest field label at this scale.
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
        let font = NSFont.systemFont(ofSize: 11, weight: .black) // closest system weight to Archivo 800
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        // `h6`'s `letter-spacing: 0.08em` needs an attributed string — NSTextField doesn't apply
        // tracking to a plain `stringValue`.
        label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: font.pointSize * 0.08
        ])
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
        label.layer?.cornerRadius = 0
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

    /// Label pinned to the row's leading edge, control pinned to its trailing edge — matches the
    /// mockup's `justify-content: space-between` treatment for these rows (`Live [toggle]`,
    /// `Record [toggle]`). Menu bar popover only — `regularFormRow` below is the desktop window's
    /// counterpart, and the two are NOT interchangeable: this one requires the caller to give the
    /// returned row an explicit width (e.g. stretching it to match its container), since
    /// leading+trailing pins with only a minimum gap between them are otherwise width-ambiguous,
    /// where `regularFormRow` stretches itself via `NSStackView` distribution.
    static func compactFormRow(label: String, control: NSView) -> NSView {
        let title = fieldLabel(label)
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(title)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8)
        ])
        return row
    }

    /// Desktop window counterpart to `compactFormRow` above — label + control in a fill-distributed
    /// `NSStackView` at `Metrics.Regular` scale. Was reimplemented privately inside
    /// `LiveTabViewController` before this moved here; promoted so the next `Regular`-scale screen
    /// doesn't have to reinvent it (or worse, reach for `compactFormRow`, which behaves differently).
    static func regularFormRow(label: String, control: NSView) -> NSView {
        let title = fieldLabel(label)
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Metrics.Regular.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: Metrics.Regular.labelWidth),
            row.heightAnchor.constraint(equalToConstant: 24)
        ])
        return row
    }

    /// Section header + a single pre-built body view, at `Regular` scale.
    static func regularSection(header: NSView, body: NSView) -> NSView {
        verticalStack([header, body], spacing: Metrics.Regular.rowSpacing)
    }

    /// Section header (from a title) + a list of rows, at `Regular` scale.
    static func regularSection(title: String, rows: [NSView]) -> NSView {
        regularSection(header: sectionHeader(title), rows: rows)
    }

    /// Section header + a list of rows, at `Regular` scale.
    static func regularSection(header: NSView, rows: [NSView]) -> NSView {
        let rowsStack = verticalStack(rows, spacing: Metrics.Regular.rowSpacing)
        let section = verticalStack([header, rowsStack], spacing: Metrics.Regular.rowSpacing)
        // `.leading`-aligned stacks only pin the leading edge of arranged subviews, they don't
        // stretch them — chain explicit width-equal constraints down so any row without its own
        // intrinsic width (e.g. AppCaptureChecklistView) doesn't end up horizontally ambiguous.
        rowsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        for row in rows {
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        return section
    }

    /// `.hr` token: a flat 2px divider fill, not a native 1px `NSBox` hairline.
    static func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.flatDivider.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 2).isActive = true
        return view
    }

    /// Native hairline, for the menu bar popover only — the flat 2px `separator()` above is for
    /// the desktop window's branded surfaces.
    static func nativeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// Native borderless link-style button, for the menu bar popover only — mirrors what this
    /// surface used before the flat/branded pass. `linkButton`/`FlatButton` below are for the
    /// desktop window.
    static func nativeLinkButton(title: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func linkButton(title: String, target: AnyObject? = nil, action: Selector? = nil) -> FlatButton {
        let button = FlatButton(title: title, kind: .ghost, target: target, action: action)
        button.pointSize = NSFont.smallSystemFontSize
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func accessoryButton(title: String, target: AnyObject? = nil, action: Selector? = nil) -> FlatButton {
        FlatButton(title: title, kind: .secondary, target: target, action: action)
    }

    /// Shared style for window-scale toolbar actions (Practice tab's Import/Record) so both use
    /// one button language instead of mixing a plain toolbar item with a custom-styled button.
    static func toolbarActionButton(title: String, symbolName: String, target: AnyObject?, action: Selector?) -> FlatButton {
        let button = FlatButton(title: title, kind: .primary, target: target, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        return button
    }

    /// Shared style for compact toggle/transport controls (Practice deck's Play/Loop/Solo/Mute)
    /// in place of stock `NSButton` bezels — flat, divider-bordered, filled solid accent when
    /// engaged (`.seg-opt:checked`-style, though these are independent toggles, not a group).
    static func toggleControlButton(title: String, target: AnyObject?, action: Selector?) -> FlatButton {
        let button = FlatButton(title: title, kind: .secondary, target: target, action: action)
        button.pointSize = NSFont.smallSystemFontSize
        button.setButtonType(.pushOnPushOff)
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

/// Layer-backed `NSButton` replacement for the native bezel styles (`.accessoryBar`,
/// `.texturedRounded`, `.accessoryBarAction`, `.inline`) this file used to reach for — flat
/// fill/border/text per REDESIGN's `.btn-primary`/`.btn-secondary`/`.btn-ghost`, zero corner
/// radius, `.btn`'s `8px 14.4px` padding and Archivo-800-equivalent (`.black`) title weight.
///
/// `title` is overridden so plain `button.title = "…"` assignments (several call sites already
/// did this against a stock `NSButton`) keep restyling automatically; `isApplyingStyle` guards
/// against the re-entrant `didSet` AppKit triggers internally when `attributedTitle` is written
/// (setting `attributedTitle` syncs `title` back, which would otherwise call `refreshStyle()`
/// a second time from inside itself).
final class FlatButton: NSButton {
    enum Kind {
        case primary
        case secondary
        case ghost
    }

    var kind: Kind {
        didSet { refreshStyle() }
    }

    /// Filled "engaged" look for toggle-style controls (Play/Loop/Solo/Mute) that isn't already
    /// covered by NSButton's own push-on/push-off `state`.
    var isOn = false {
        didSet { refreshStyle() }
    }

    /// Overrides `.secondary`'s engaged fill color — Mute wants red, not the default accent.
    var engagedFillColorOverride: NSColor? {
        didSet { refreshStyle() }
    }

    /// Overrides `.ghost`'s default accent text color — the popover footer's Open/Quit links
    /// intentionally read as plain text, not an accent-colored CTA.
    var textColorOverride: NSColor? {
        didSet { refreshStyle() }
    }

    var pointSize: CGFloat = 14 {
        didSet { refreshStyle() }
    }

    private var isApplyingStyle = false

    override var title: String {
        didSet {
            guard !isApplyingStyle else { return }
            refreshStyle()
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    init(title: String, kind: Kind, target: AnyObject? = nil, action: Selector? = nil) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        refreshStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshStyle() {
        isApplyingStyle = true
        defer { isApplyingStyle = false }

        let engaged = isOn || state == .on
        let font = NSFont.systemFont(ofSize: pointSize, weight: .black)
        let textColor: NSColor
        switch kind {
        case .primary:
            layer?.backgroundColor = NSColor.brandAccent.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            textColor = .white
        case .secondary:
            let fillColor = engagedFillColorOverride ?? .brandAccent
            layer?.backgroundColor = (engaged ? fillColor : .clear).cgColor
            layer?.borderColor = NSColor.flatDivider.cgColor
            textColor = engaged ? .white : .labelColor
        case .ghost:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            textColor = textColorOverride ?? .brandAccent
        }

        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])
        contentTintColor = textColor
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        guard size.width > 0 else { return size }
        size.width += 14.4 * 2
        size.height += 8 * 2
        return size
    }
}

/// Flat stand-in for `NSSegmentedControl`'s native pill chrome — fighting `NSSegmentStyle` to
/// fully flatten it is less reliable than owning the drawing outright. Mirrors REDESIGN's
/// `.seg`/`.seg-opt` tokens (1px divider border/separators, selected segment filled solid
/// `brandAccent` with bg-colored text) while exposing just enough of `NSSegmentedControl`'s
/// surface (`selectedSegment`/`target`/`action`) for `MainWindowController` to drop in as a
/// replacement. Explicitly reports the `AXRadioGroup`/`AXRadioButton` accessibility roles
/// `NSSegmentedControl` gets for free, since the UI test suite queries for exactly that shape.
final class FlatSegmentedControl: NSView {
    private var buttons: [NSButton] = []
    private let optionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Faint capsule track the sliding pill sits inside — without it the control has no visible
    /// footprint in its unselected state, just floating text.
    private let track = NSView()
    /// The sliding accent-filled capsule behind whichever segment is selected.
    private let selectionPill = NSView()
    private var pillLeading: NSLayoutConstraint?
    private var pillTrailing: NSLayoutConstraint?
    private static let pillInset: CGFloat = 3

    var target: AnyObject?
    var action: Selector?

    var selectedSegment: Int = 0 {
        didSet { updateSelectionAppearance(animated: true) }
    }

    init(titles: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)

        selectionPill.wantsLayer = true
        selectionPill.layer?.backgroundColor = NSColor.brandAccent.cgColor
        selectionPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionPill)

        var previousTrailing = leadingAnchor
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(segmentClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.setAccessibilityRole(.radioButton)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            buttons.append(button)

            let textWidth = (title as NSString).size(withAttributes: [.font: optionFont]).width
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: previousTrailing),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.widthAnchor.constraint(equalToConstant: ceil(textWidth) + 28)
            ])
            previousTrailing = button.trailingAnchor
        }
        previousTrailing.constraint(equalTo: trailingAnchor).isActive = true

        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionPill.topAnchor.constraint(equalTo: topAnchor, constant: Self.pillInset),
            selectionPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.pillInset)
        ])

        updateSelectionAppearance(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        track.layer?.cornerRadius = track.bounds.height / 2
        selectionPill.layer?.cornerRadius = selectionPill.bounds.height / 2
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioGroup
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        selectedSegment = sender.tag
        if let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func updateSelectionAppearance(animated: Bool) {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedSegment
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: optionFont,
                .foregroundColor: selected ? NSColor.white : NSColor.secondaryLabelColor
            ])
        }

        guard selectedSegment < buttons.count else { return }
        let selectedButton = buttons[selectedSegment]
        pillLeading?.isActive = false
        pillTrailing?.isActive = false
        pillLeading = selectionPill.leadingAnchor.constraint(equalTo: selectedButton.leadingAnchor, constant: Self.pillInset)
        pillTrailing = selectionPill.trailingAnchor.constraint(equalTo: selectedButton.trailingAnchor, constant: -Self.pillInset)
        pillLeading?.isActive = true
        pillTrailing?.isActive = true

        guard animated else {
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }
}

/// Status row: title only. For errors, an info button shows the message on click.
final class StatusHeaderView: NSView {
    // Left as a circle, not squared off — a status dot is an indicator glyph, not one of the
    // box-shaped elements (buttons/panels/rows) the design system's zero-radius tokens target.
    private let dot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let infoButton = FlatButton(title: "", kind: .ghost)
    private var errorDetail: String?
    private var infoPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .black) // Archivo-800-equivalent
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
        infoButton.textColorOverride = .secondaryLabelColor
        infoButton.target = self
        infoButton.action = #selector(showErrorInfo)
        infoButton.isHidden = true
        infoButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(titleField)
        addSubview(infoButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PopoverUI.Metrics.rowHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            titleField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
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
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
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
