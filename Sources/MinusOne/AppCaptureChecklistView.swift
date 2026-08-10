import AppKit
import CoreAudio

/// Real multi-select checklist for Custom capture scope (REDESIGN.md §3), replacing the old
/// single-selection popup-within-a-popup. Reuses `AudioProcessEnumerator` for process discovery
/// and icons; persists through `Preferences.selectedAppBundleIDs` via `AudioEngine`.
@available(macOS 14.2, *)
final class AppCaptureChecklistView: NSView {
    private enum Layout {
        static let rowHeight: CGFloat = 26
        static let maxVisibleRows: CGFloat = 4.5
    }

    private let preferences: Preferences
    private let audioEngine: AudioEngine
    private let stack = NSStackView()
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

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // `stack` is the scroll view's documentView directly, not wrapped in a plain NSView.
        // NSStackView.isFlipped is true, so its (0,0) is the visual top — matching the clip
        // view's default unscrolled origin, which shows the top of the content. A plain NSView
        // wrapper is *not* flipped by default, so the clip view's default origin showed the
        // *bottom* of the list instead, clipping the first row under the row above it.
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Layout.rowHeight * Layout.maxVisibleRows),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: rowHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 16),
            checkmark.heightAnchor.constraint(equalToConstant: 16)
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
