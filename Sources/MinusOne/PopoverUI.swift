import AppKit

/// The menu bar popover's chrome — the one surface that stays fully native macOS materials/shape
/// (per design direction: native there, flat/branded reserved for the desktop window, which is
/// `WindowUI`'s job). Nothing in this file is ever used by the desktop window.
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
        /// This rounding is only ever consumed by `makeMenuRoot`/`makeEffectView`.
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

    /// Label pinned to the row's leading edge, control pinned to its trailing edge — matches the
    /// mockup's `justify-content: space-between` treatment for these rows (`Live [toggle]`,
    /// `Record [toggle]`). Menu bar popover only — `WindowUI.formRow` is the desktop window's
    /// counterpart, and the two are NOT interchangeable: this one requires the caller to give the
    /// returned row an explicit width (e.g. stretching it to match its container), since
    /// leading+trailing pins with only a minimum gap between them are otherwise width-ambiguous,
    /// where `WindowUI.formRow` stretches itself via `NSStackView` distribution.
    static func compactFormRow(label: String, control: NSView) -> NSView {
        let title = SharedUI.fieldLabel(label)
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

    /// Native hairline, for the menu bar popover only — `WindowUI.separator()` (a flat 2px fill)
    /// is for the desktop window's branded surfaces.
    static func nativeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// Native borderless link-style button, for the menu bar popover only — mirrors what this
    /// surface used before the flat/branded pass. `WindowUI.linkButton`/`FlatButton` are for the
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
}
