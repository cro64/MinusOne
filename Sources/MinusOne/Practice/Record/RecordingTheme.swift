import AppKit

/// Recording panel palette, aligned onto the app-wide brand system (REDESIGN.md §7) rather than
/// a bespoke "tape deck" look. The panel is forced into dark appearance by its presenting popover
/// (see `PracticeWindowController`), so these semantic colors resolve to the same dark surface
/// tones `SettingsPopoverViewController` and `MainWindowController` use.
enum RecordingTheme {
    static let background = NSColor.windowBackgroundColor
    static let panel = NSColor.controlBackgroundColor
    static let cream = NSColor.labelColor
    static let putty = NSColor.secondaryLabelColor
    static let amber = NSColor.brandAccent
    static let amberDim = NSColor.brandAccent.withAlphaComponent(0.35)
    static let teal = NSColor.secondaryLabelColor
    static let red = NSColor.systemRed
    static let redDim = NSColor.systemRed.withAlphaComponent(0.35)
    static let hairline = NSColor.separatorColor

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func sans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

/// A borderless button with a solid, colored, rounded background — the "arm-btn"/"stop-btn" look.
final class ThemedButton: NSButton {
    enum Style {
        case filled(background: NSColor, foreground: NSColor)
        case outlined(border: NSColor, foreground: NSColor)
    }

    private var style: Style
    private let cornerRadius: CGFloat = 6

    init(title: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        font = RecordingTheme.sans(13, weight: .semibold)
        layer?.cornerRadius = cornerRadius
        contentTintColor = foregroundColor
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStyle(_ style: Style) {
        self.style = style
        applyStyle()
    }

    private var foregroundColor: NSColor {
        switch style {
        case .filled(_, let foreground): return foreground
        case .outlined(_, let foreground): return foreground
        }
    }

    private func applyStyle() {
        contentTintColor = foregroundColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: foregroundColor, .font: font as Any]
        )
        switch style {
        case .filled(let background, _):
            layer?.backgroundColor = background.cgColor
            layer?.borderWidth = 0
        case .outlined(let border, _):
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = border.cgColor
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 40)
    }
}

/// A small rounded pill with a border and colored text — the "Not recording" mode tag.
final class TagView: NSTextField {
    init(text: String, color: NSColor) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = RecordingTheme.mono(10, weight: .medium)
        textColor = color
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = color.withAlphaComponent(0.4).cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
