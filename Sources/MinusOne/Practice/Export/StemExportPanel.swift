import AppKit

/// The save panel for one stem, with its format popup.
///
/// A type rather than inline setup in the view controller for two reasons: `NSPopUpButton.target`
/// is unowned, so something has to own the handler until the sheet closes, and the name/content
/// type pairing below is the part worth testing without putting a sheet on screen.
final class StemExportPanel: NSObject {
    let panel = NSSavePanel()
    private(set) var format: StemExportFormat

    private let popUp = NSPopUpButton()

    init(clipTitle: String, stem: SeparationStem, format: StemExportFormat) {
        self.format = format
        super.init()

        panel.nameFieldStringValue = StemExportNaming.suggestedFileName(
            clipTitle: clipTitle,
            stem: stem,
            format: format
        )
        panel.allowedContentTypes = [format.contentType]

        WindowUI.configurePopUp(popUp)
        for candidate in StemExportFormat.allCases {
            popUp.addItem(withTitle: candidate.displayName)
            popUp.lastItem?.representedObject = candidate.rawValue
        }
        popUp.selectItem(at: StemExportFormat.allCases.firstIndex(of: format) ?? 0)
        popUp.target = self
        popUp.action = #selector(popUpChanged(_:))

        let label = SharedUI.fieldLabel("Format")
        let row = Layout.horizontalStack([label, popUp], spacing: WindowUI.Metrics.rowSpacing)
        let container = AutoLayoutView()
        container.addSubview(row)
        Layout.pin(row, to: container, insets: NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
        panel.accessoryView = container
    }

    /// Moves the name and the content type together. `NSSavePanel` appends the extension from
    /// `allowedContentTypes` on its own, so changing only one of the two leaves the panel
    /// re-appending the format the user just switched away from.
    func selectFormat(_ newFormat: StemExportFormat) {
        format = newFormat
        panel.allowedContentTypes = [newFormat.contentType]
        panel.nameFieldStringValue = StemExportNaming.replacingExtension(
            in: panel.nameFieldStringValue,
            with: newFormat
        )
    }

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let selected = StemExportFormat(rawValue: raw) else { return }
        selectFormat(selected)
    }
}
