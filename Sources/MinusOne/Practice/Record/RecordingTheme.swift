import AppKit

/// Dark, warm-toned palette for the recording panel — distinct from the rest of the app's
/// system-vibrancy chrome, since this surface is meant to read like a dedicated "tape deck".
enum RecordingTheme {
    static let background = NSColor(hex: 0x181614)
    static let panel = NSColor(hex: 0x1F1C19)
    static let cream = NSColor(hex: 0xEAE4D8)
    static let putty = NSColor(hex: 0x8B8478)
    static let amber = NSColor(hex: 0xC9784A)
    static let amberDim = NSColor(hex: 0x6E4429)
    static let teal = NSColor(hex: 0x5C8C82)
    static let red = NSColor(hex: 0xC4574A)
    static let redDim = NSColor(hex: 0x5C2E28)
    static let hairline = NSColor(hex: 0x3A352E)

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func sans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
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
