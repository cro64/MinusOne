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
        /// Inset between a card's border and its content — space-4, matching `sectionSpacing` so
        /// a card's inner rhythm lines up with the gaps between cards.
        static let cardPadding: CGFloat = 16
        /// Gap between adjacent cards in the Live tab's grid — space-4.
        static let cardSpacing: CGFloat = 16
        static let cardCornerRadius: CGFloat = 10
        /// Gap between a button's leading icon and its title. `NSButton` exposes no image/title
        /// spacing, and `imageHugsTitle` alone leaves them ~2pt apart, so this is baked into the
        /// image's trailing edge instead.
        static let iconTitleSpacing: CGFloat = 5
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
        let section = Layout.verticalStack([header, body], spacing: Metrics.rowSpacing)
        // `.leading`-aligned stacks only pin arranged subviews' leading edge, they don't stretch
        // them — without this, `body` (and everything nested under it) shrinks to its own minimum
        // intrinsic width instead of using the space the section actually has.
        body.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
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

    /// A `section(...)` wrapped in card chrome — the Live tab's grid unit. Kept here rather than
    /// built per-call-site so the `.leading`-stack width-chaining that `section(...)` already gets
    /// right isn't reimplemented (and re-broken) inside each card.
    static func card(header: NSView, body: NSView) -> NSView {
        card(content: section(header: header, body: body))
    }

    /// Card chrome around a section built from rows.
    static func card(title: String, rows: [NSView]) -> NSView {
        card(content: section(title: title, rows: rows))
    }

    /// Card chrome around arbitrary content (the Live tab's status hero, which isn't a `section`).
    static func card(content: NSView) -> NSView {
        let container = ThemedView(fill: .cardBackground, stroke: .cardBorder)
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = Metrics.cardCornerRadius

        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        Layout.pin(content, to: container, insets: NSEdgeInsets(
            top: Metrics.cardPadding,
            left: Metrics.cardPadding,
            bottom: Metrics.cardPadding,
            right: Metrics.cardPadding
        ))
        return container
    }

    /// `.hr` token: a flat 2px divider fill, not a native 1px `NSBox` hairline (that's
    /// `PopoverUI.nativeSeparator`, for the popover only).
    static func separator() -> NSView {
        let view = ThemedView(fill: .flatDivider)
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
    /// `symbolPointSize` is taken here rather than left to the caller to re-apply afterwards: the
    /// icon/title gap is baked into the image, so a later `button.image = button.image?
    /// .withSymbolConfiguration(…)` would silently throw the spacing away.
    static func toolbarActionButton(
        title: String,
        symbolName: String,
        symbolPointSize: CGFloat = 14,
        target: AnyObject?,
        action: Selector?
    ) -> FlatButton {
        let button = FlatButton(title: title, kind: .primary, target: target, action: action)
        button.setSymbol(symbolName, pointSize: symbolPointSize, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        // Without this, `NSButtonCell` pins the image to the button's leading edge and then centers
        // the title inside *all* the remaining width — measured on the 93pt Import button: image at
        // x=0 (flush to the edge) with the title rect running to x=93, which reads as an icon stuck
        // to the rim and a large gap before the label. `FlatButton` inflates `intrinsicContentSize`
        // by 14.4pt a side, so there is always surplus width for that to go wrong in. Hugging keeps
        // image and title together as one group and centers the pair: 16.5pt of padding on both
        // sides, measured.
        button.imageHugsTitle = true
        return button
    }

    /// Icon-only transport control (Practice deck's back/play/forward/loop). Same flat
    /// `.secondary` chrome as `toggleControlButton` — so a toggled Loop still fills solid accent —
    /// but sized as a square-ish glyph button instead of a text one. The 33pt height is the height
    /// the row's text buttons measured, so swapping labels for glyphs doesn't reflow the deck.
    static func transportButton(
        symbolName: String,
        label: String,
        target: AnyObject?,
        action: Selector?
    ) -> FlatButton {
        let button = FlatButton(title: "", kind: .secondary, target: target, action: action)
        // A momentary action must never paint the engaged fill: `state` gets set on these anyway
        // (measured — even a stock `NSButton` set to `.momentaryPushIn` comes back from a click
        // with `state == .on`), and the Forward glyph ended up latched in solid accent as though
        // it were a mode. `transportToggleButton` is the variant for controls that *are* modes.
        button.setButtonType(.momentaryPushIn)
        button.reflectsState = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setIcon(symbolName, label: label)
        button.constrainSize(width: 40, height: 33)
        return button
    }

    /// `transportButton` for a control that latches — Practice's Loop. Same glyph chrome, but it
    /// keeps its state and shows the engaged accent fill while on.
    static func transportToggleButton(
        symbolName: String,
        label: String,
        target: AnyObject?,
        action: Selector?
    ) -> FlatButton {
        let button = transportButton(symbolName: symbolName, label: label, target: target, action: action)
        button.setButtonType(.pushOnPushOff)
        button.reflectsState = true
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

extension FlatButton {
    /// Sets an SF Symbol as the button's image with the icon/title gap baked in. The only correct
    /// way to *change* a `toolbarActionButton`'s icon after construction: a plain `button.image = …`
    /// loses `withTrailingPadding`, and the button silently reverts to the ~2pt gap `imageHugsTitle`
    /// leaves on its own. Used by Practice's Record button, which swaps to a Stop glyph mid-session.
    func setSymbol(_ symbolName: String, pointSize: CGFloat = 14, accessibilityDescription: String? = nil) {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))?
            .withTrailingPadding(WindowUI.Metrics.iconTitleSpacing)
    }
}

extension FlatButton {
    /// Icon for an image-only button, plus the label a glyph can't carry on its own — the
    /// accessibility name and the tooltip both come from it, so a bare symbol is still
    /// identifiable. Unlike `setSymbol`, no trailing padding: there is no title to sit beside.
    func setIcon(_ symbolName: String, pointSize: CGFloat = 13, label: String) {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        setAccessibilityLabel(label)
        toolTip = label
    }
}

extension NSImage {
    /// Copy with `points` of transparent space on the trailing edge — the only way to put a gap
    /// between an `NSButton`'s icon and its title, since the cell offers no spacing knob.
    /// `isTemplate` is carried over so SF Symbols keep taking their color from `contentTintColor`
    /// rather than being flattened into the bitmap.
    func withTrailingPadding(_ points: CGFloat) -> NSImage {
        guard points > 0 else { return self }
        let padded = NSImage(size: NSSize(width: size.width + points, height: size.height))
        padded.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        padded.unlockFocus()
        padded.isTemplate = isTemplate
        return padded
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

    enum CornerStyle {
        /// Fixed `WindowUI.Metrics.buttonCornerRadius` — the default for buttons sitting in a
        /// card's form rhythm, where a capsule would fight the square-ish chrome around it.
        case rounded
        /// Fully round ends, radius tracking half the button's height. Used by Practice's
        /// Import/Record row, which sits directly under the title bar's capsule Live/Practice
        /// switch and reads as part of that same band of controls.
        case capsule
    }

    var cornerStyle: CornerStyle = .rounded {
        didSet { needsLayout = true }
    }

    var kind: Kind {
        didSet { refreshStyle() }
    }

    /// Filled "engaged" look for toggle-style controls (Play/Loop/Solo/Mute) that isn't already
    /// covered by NSButton's own push-on/push-off `state`.
    var isOn = false {
        didSet { refreshStyle() }
    }

    /// Whether `state == .on` should paint the engaged fill. True for genuine toggles
    /// (Loop/Solo/Mute); false for momentary actions, whose `state` is incidental — AppKit leaves
    /// it set after a click regardless of button type, which is enough to latch the fill on.
    var reflectsState = true {
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

    /// A capsule's radius depends on the resolved height, so it can't be set once in `init` the
    /// way the fixed radius can.
    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerStyle == .capsule
            ? bounds.height / 2
            : WindowUI.Metrics.buttonCornerRadius
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

    /// Ghost/secondary buttons derive their fill and border from `labelColor`/`flatDivider`, which
    /// invert between appearances — and a layer's colors are frozen `CGColor`s, so they have to be
    /// rewritten rather than left to update themselves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }

    func refreshStyle() {
        isApplyingStyle = true
        defer { isApplyingStyle = false }

        let engaged = isOn || (reflectsState && state == .on)
        let font = NSFont.systemFont(ofSize: pointSize, weight: .black)
        var textColor: NSColor = .labelColor
        resolvingEffectiveAppearance {
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
        }

        // Outside the block on purpose: `attributedTitle` and `contentTintColor` hold the `NSColor`
        // itself, so they re-resolve on their own and want the dynamic value, not a snapshot.
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])
        contentTintColor = textColor
    }

    /// `NSButton` reports insets derived from the native bezel it would normally draw (measured:
    /// top 4, bottom 3.5, right 0.5). Auto Layout constrains the *alignment rect*, not the frame,
    /// so those insets silently inflate the painted box — a `constrainSize(24, 24)` produced a
    /// 24.5×31.5 layer, which rendered the capsule hover as a vertical oval rather than a circle,
    /// and made the 26pt Import/Record buttons paint 33.5pt tall inside a 26pt row.
    ///
    /// `FlatButton` sets `isBordered = false` and paints its own fill, border and corner radius
    /// into its layer from `bounds`, so there is no bezel for the insets to describe. Zeroing them
    /// makes the painted box exactly the size that was constrained.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        guard size.width > 0 else { return size }
        // `.btn`'s 8pt × 14.4pt padding is *text* padding. An icon-only button (empty title, as in
        // the title bar's theme switch and `StatusHeaderView`'s info button) has no text to pad,
        // and adding it anyway inflates the intrinsic height enough to fight the square size those
        // call sites constrain — leaving a 24×30 button whose capsule hover renders as a vertical
        // oval rather than a circle.
        guard !title.isEmpty else { return size }
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
    private let track = ThemedView(frame: .zero)
    /// The sliding accent-filled capsule behind whichever segment is selected.
    private let selectionPill = ThemedView(frame: .zero)
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

        // `labelTint`, not `labelColor.withAlphaComponent` — the latter resolves immediately and
        // would store a fixed dark wash that never flips to a light one.
        track.fillColor = .labelTint(0.06)
        addSubview(track)

        selectionPill.fillColor = .brandAccent
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
