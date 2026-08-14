import AppKit

/// Practice deck's empty state (REDESIGN.md §4): the logo's waveform mark plus two direct
/// actions, wired to the same Import/Record actions as the toolbar rather than prose telling
/// the user what to do elsewhere.
final class PracticeEmptyStateView: NSView {
    var onImportRequested: (() -> Void)?
    var onRecordRequested: (() -> Void)?

    private let importButton: NSButton
    private let recordButton: NSButton

    override init(frame frameRect: NSRect) {
        let mark = NSImageView(image: MinusOneIcon.waveform(size: 56, color: .tertiaryLabelColor, isActive: false))
        mark.constrainSize(width: 56, height: 56)

        let title = NSTextField(labelWithString: "No clip selected")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Import a clip or record system audio to start practicing.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping

        importButton = WindowUI.toolbarActionButton(title: "Import a clip", symbolName: "square.and.arrow.down", target: nil, action: nil)
        recordButton = WindowUI.toolbarActionButton(title: "Record system audio", symbolName: "record.circle", target: nil, action: nil)

        let actionsRow = Layout.horizontalStack([importButton, recordButton], spacing: WindowUI.Metrics.rowSpacing)

        let stack = Layout.verticalStack([mark, title, subtitle, actionsRow], spacing: WindowUI.Metrics.rowSpacing)
        stack.alignment = .centerX
        stack.setCustomSpacing(WindowUI.Metrics.sectionSpacing, after: mark)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(WindowUI.Metrics.sectionSpacing, after: subtitle)

        super.init(frame: frameRect)

        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        Layout.pin(stack, to: self)

        importButton.target = self
        importButton.action = #selector(importClicked)
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func importClicked() {
        onImportRequested?()
    }

    @objc private func recordClicked() {
        onRecordRequested?()
    }
}
