import AppKit

/// The desktop window's flat/branded design system (REDESIGN.md §6) — as opposed to `PopoverUI`,
/// which is native macOS chrome reserved for the menu bar popover. Nothing in this file is ever
/// used by the popover.
enum WindowUI {
    enum Metrics {
        static let padding: CGFloat = 24 // space-6
        static let sectionSpacing: CGFloat = 16 // space-4
        static let rowSpacing: CGFloat = 8 // space-2
        /// Composed (space-8 + space-8), not a raw token — sized to fit "Intensity", the
        /// widest field label at this scale.
        static let labelWidth: CGFloat = 64
        /// `FlatButton`'s corner radius — softens the previously-square "Modernist" buttons per
        /// user direction; kept smaller than the popover's corner radius so buttons still read
        /// as flat/branded rather than native-rounded.
        static let buttonCornerRadius: CGFloat = 6
        /// Minimum track length for Live tab's Intensity/Gain sliders.
        static let sliderMinWidth: CGFloat = 88
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

    /// Label + control in a fill-distributed `NSStackView` at window scale. Was reimplemented
    /// privately inside `LiveTabViewController` before this moved here; promoted so the next
    /// screen doesn't have to reinvent it (or reach for `PopoverUI.compactFormRow`, which behaves
    /// differently — that one is the menu bar popover's counterpart, not interchangeable with
    /// this one).
    static func formRow(label: String, control: NSView) -> NSView {
        let title = SharedUI.fieldLabel(label)
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Metrics.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: Metrics.labelWidth),
            row.heightAnchor.constraint(equalToConstant: 24)
        ])
        return row
    }

    /// Section header + a single pre-built body view.
    static func section(header: NSView, body: NSView) -> NSView {
        Layout.verticalStack([header, body], spacing: Metrics.rowSpacing)
    }

    /// Section header (from a title) + a list of rows.
    static func section(title: String, rows: [NSView]) -> NSView {
        section(header: SharedUI.sectionHeader(title), rows: rows)
    }

    /// Section header + a list of rows.
    static func section(header: NSView, rows: [NSView]) -> NSView {
        let rowsStack = Layout.verticalStack(rows, spacing: Metrics.rowSpacing)
        let section = Layout.verticalStack([header, rowsStack], spacing: Metrics.rowSpacing)
        // `.leading`-aligned stacks only pin the leading edge of arranged subviews, they don't
        // stretch them — chain explicit width-equal constraints down so any row without its own
        // intrinsic width (e.g. AppCaptureChecklistView) doesn't end up horizontally ambiguous.
        rowsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        for row in rows {
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        return section
    }

    /// `.hr` token: a flat 2px divider fill, not a native 1px `NSBox` hairline (that's
    /// `PopoverUI.nativeSeparator`, for the popover only).
    static func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.flatDivider.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 2).isActive = true
        return view
    }

    static func linkButton(title: String, target: AnyObject? = nil, action: Selector? = nil) -> FlatButton {
        let button = FlatButton(title: title, kind: .ghost, target: target, action: action)
        button.pointSize = NSFont.smallSystemFontSize
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
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
}

/// Layer-backed `NSButton` replacement for the native bezel styles (`.accessoryBar`,
/// `.texturedRounded`, `.accessoryBarAction`, `.inline`) this file used to reach for — flat
/// fill/border/text per REDESIGN's `.btn-primary`/`.btn-secondary`/`.btn-ghost`, `.btn`'s
/// `8px 14.4px` padding and Archivo-800-equivalent (`.black`) title weight. Corners are rounded
/// (`WindowUI.Metrics.buttonCornerRadius`) rather than the original design's square corners, and
/// hover/press states lighten/darken the fill so buttons read as clickable — both per user
/// direction.
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

    /// Cursor is over the button — lightens filled backgrounds, tints unfilled ones.
    private var isHovering = false {
        didSet { refreshStyle() }
    }

    /// Mouse is down inside the button (set for the duration of `mouseDown(with:)`'s tracking
    /// loop) — darkens filled backgrounds, tints unfilled ones more strongly than hover.
    private var isPressed = false {
        didSet { refreshStyle() }
    }

    private var trackingArea: NSTrackingArea?

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
        layer?.cornerRadius = WindowUI.Metrics.buttonCornerRadius
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        isPressed = true
        // NSButton's mouseDown(with:) runs its own tracking loop and only returns once the
        // mouse goes up (after sending the action), so isPressed correctly spans the whole
        // press-and-hold gesture.
        super.mouseDown(with: event)
        isPressed = false
    }

    /// Blends `base` toward black (pressed) or white (hover) for filled buttons; for unfilled
    /// buttons (`base == .clear`), shows a faint `labelColor` tint instead since blending a
    /// transparent color has no visible effect.
    private func interactionFill(base: NSColor, isFilled: Bool) -> NSColor {
        guard isFilled else {
            if isPressed { return NSColor.labelColor.withAlphaComponent(0.14) }
            if isHovering { return NSColor.labelColor.withAlphaComponent(0.07) }
            return .clear
        }
        if isPressed { return base.blended(withFraction: 0.25, of: .black) ?? base }
        if isHovering { return base.blended(withFraction: 0.12, of: .white) ?? base }
        return base
    }

    func refreshStyle() {
        isApplyingStyle = true
        defer { isApplyingStyle = false }

        let engaged = isOn || state == .on
        let font = NSFont.systemFont(ofSize: pointSize, weight: .black)
        let textColor: NSColor
        switch kind {
        case .primary:
            layer?.backgroundColor = interactionFill(base: .brandAccent, isFilled: true).cgColor
            layer?.borderColor = NSColor.clear.cgColor
            textColor = .white
        case .secondary:
            let fillColor = engagedFillColorOverride ?? .brandAccent
            layer?.backgroundColor = interactionFill(base: fillColor, isFilled: engaged).cgColor
            layer?.borderColor = NSColor.flatDivider.cgColor
            textColor = engaged ? .white : .labelColor
        case .ghost:
            layer?.backgroundColor = interactionFill(base: .clear, isFilled: false).cgColor
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

/// Slider that reports drag begin/end so callers can show a transient value overlay. Window-only —
/// used by `LiveTabViewController`'s Intensity/Gain sliders.
final class DragValueSlider: NSSlider {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
        defer { onDragEnded?() }
        super.mouseDown(with: event)
    }
}
