import AppKit
import CoreAudio

/// Real multi-select checklist for Custom capture scope (REDESIGN.md §3), replacing the old
/// single-selection popup-within-a-popup. Reuses `AudioProcessEnumerator` for process discovery
/// and icons; persists through `Preferences.selectedAppBundleIDs` via `AudioEngine`.
@available(macOS 14.2, *)
final class AppCaptureChecklistView: NSView {
    private enum Layout {
        static let rowHeight: CGFloat = 26
    }

    private let preferences: Preferences
    private let audioEngine: AudioEngine
    private let stack = FlippedStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No audio apps found — open one and play a track.")

    /// Whether rows can be tapped — disabled (but still visible) when the Scope isn't Custom.
    var isEnabled = true {
        didSet { reload() }
    }

    init(preferences: Preferences, audioEngine: AudioEngine) {
        self.preferences = preferences
        self.audioEngine = audioEngine
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Both the fill and the border derive from system colors that invert between appearances, and
    /// a layer stores them as frozen `CGColor`s — so they get rewritten here rather than only in
    /// `configure()`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    private func applyChromeColors() {
        resolvingEffectiveAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyChromeColors()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // `stack` is the scroll view's documentView directly, not wrapped in a plain NSView —
        // and it's flipped, which it has to be explicitly: `NSStackView.isFlipped` is *false*
        // (measured), so a stock one puts (0,0) at the visual bottom. A clip view's default
        // unscrolled origin is (0,0), so the list opened showing its **last** row with the rest
        // scrolled off above — the picker looked stuck at the end of the alphabet. Flipped,
        // (0,0) is the top and an unscrolled list starts at the first app.
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        MinusOne.Layout.pin(scrollView, to: self)

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        // How tall the list asks to be. Note this *has* to be a constraint rather than a content
        // hugging priority: the view has no `intrinsicContentSize`, so hugging on it is inert.
        //
        // Breakable, so the card can still squeeze it, but no longer the single row it used to
        // ask for. That one-row preference was meant to let the card decide, except nothing else
        // in the card ever pulled it taller: the picker settled at exactly 26pt in the shipping
        // window (measured over the running app) — a sliver showing one row of a 16-app list,
        // which is not a picker. Five rows is what it takes to choose between apps rather than
        // scroll a keyhole; the Live tab's hero meter, which hugs at priority 1 and had ~436pt,
        // is what gives up the room.
        let preferredHeight = heightAnchor.constraint(equalToConstant: Layout.rowHeight * 5)
        preferredHeight.priority = .defaultLow
        preferredHeight.isActive = true

        NSLayoutConstraint.activate([
            // A row of list is the hard floor: enough that the control still reads as a list.
            heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.rowHeight),
            // Tied to the clip view, not to `scrollView` itself. A legacy (always-visible)
            // vertical scroller takes its 17pt out of the clip view's width while the scroll
            // view stays the same, so measuring against the scroll view made every row 17pt
            // wider than the visible area — the list scrolled sideways for no reason
            // (measured: document 314pt inside a 297pt clip view). The clip view is the width
            // the rows are actually seen at, so the app names truncate instead.
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])

        reload()
    }

    func reload() {
        let selected = preferences.selectedAppBundleIDs
        let apps = AudioProcessEnumerator.processesForAppPicker(includingSelected: selected)

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !apps.isEmpty
        scrollView.isHidden = apps.isEmpty

        for app in apps {
            let row = AppChecklistRow(
                app: app,
                isSelected: selected.contains(app.bundleID),
                rowHeight: Layout.rowHeight,
                isEnabled: isEnabled
            ) { [weak self] bundleID in
                self?.audioEngine.toggleSelectedAppBundleID(bundleID)
                self?.reload()
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// Vertical stack whose origin is its top, so it can be a scroll view's document view directly
/// without the content reading upside-down. See `configure()`.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@available(macOS 14.2, *)
private final class AppChecklistRow: NSView {
    private let bundleID: String
    private let onToggle: (String) -> Void
    private let checkmark = NSImageView()
    private var isSelected: Bool

    init(
        app: AudioClientProcess,
        isSelected: Bool,
        rowHeight: CGFloat,
        isEnabled: Bool,
        onToggle: @escaping (String) -> Void
    ) {
        bundleID = app.bundleID
        self.isSelected = isSelected
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = AppChecklistRow.icon(for: app.bundleID)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: app.displayName)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.toolTip = AppChecklistRow.tooltip(for: app)

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(checkmark)

        if isEnabled {
            let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
            addGestureRecognizer(click)
        }

        iconView.constrainSize(width: 16, height: 16)
        checkmark.constrainSize(width: 16, height: 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: rowHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateCheckmark()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        isSelected.toggle()
        updateCheckmark()
        onToggle(bundleID)
    }

    private func updateCheckmark() {
        let symbolName = isSelected ? "checkmark.circle.fill" : "circle"
        checkmark.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        checkmark.contentTintColor = isSelected ? .brandAccent : .tertiaryLabelColor
    }

    private static func icon(for bundleID: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    private static func tooltip(for app: AudioClientProcess) -> String? {
        if app.isRunningOutput {
            return nil
        }
        if app.objectID != kAudioObjectUnknown {
            return "Start playback in this app before enabling reduction"
        }
        return "Play audio once so MinusOne can attach to this app"
    }
}
