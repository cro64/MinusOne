import AppKit

/// Label factories and components genuinely shared by both `PopoverUI` (menu bar popover, native
/// chrome) and `WindowUI` (desktop window, flat/branded chrome) — none of these carry an opinion
/// about which scale or design language they're used at.
enum SharedUI {
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
}

/// Status row: title only. For errors, an info button shows the message on click. Used by both
/// `LiveTabViewController` (window) and `MenuBarPopoverViewController` (popover).
final class StatusHeaderView: NSView {
    /// Fixed row height regardless of which scale the caller otherwise uses — this component
    /// doesn't derive its size from either `PopoverUI.Metrics` or `WindowUI.Metrics`.
    private static let height: CGFloat = 20

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

        dot.constrainSize(width: 8, height: 8)
        infoButton.constrainSize(width: 16, height: 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoButton.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
            infoButton.centerYAnchor.constraint(equalTo: centerYAnchor)
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
