import AppKit
import UniformTypeIdentifiers

/// Drop target that forwards dragged file URLs — used as the sidebar's root view so dropping an
/// audio file onto the library list imports it.
private final class DropTargetView: AutoLayoutView {
    var onDropFiles: (([URL]) -> Void)?

    override func awakeFromNib() { super.awakeFromNib() }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            return false
        }
        onDropFiles?(urls)
        return true
    }
}

final class ClipSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let libraryStore: ClipLibraryStore
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private var allClips: [PracticeClip] = []
    private var filteredClips: [PracticeClip] = []

    var onSelectClip: ((PracticeClip) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    /// Fired after a rename has been persisted, so the deck showing the same clip re-titles too.
    var onRenameClip: ((PracticeClip) -> Void)?

    init(libraryStore: ClipLibraryStore) {
        self.libraryStore = libraryStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = DropTargetView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        root.onDropFiles = { [weak self] urls in self?.onDropFiles?(urls) }
        view = root

        // The sidebar's translucent background used to come from
        // `NSSplitViewItem(sidebarWithViewController:)`. That item type assumes the full-height
        // sidebar pattern — content running up under the title bar — so in a `.fullSizeContentView`
        // window it reserves title-bar room at its top whether or not it actually sits there.
        // Measured: 24pt of dead space above the search field, even though `PracticeTabViewController`
        // places this pane well below the header. `PracticeSplitViewController` now uses a plain
        // item, and the material moves here, where it can be applied without that assumption.
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        Layout.pin(background, to: root)

        searchField.placeholderString = "Search clips"
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: .init("clip"))
        column.width = 240
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // 62, not 56. `ClipRowView` needs 60pt for its three stacked pieces at their intrinsic
        // heights (6 + title 15 + 1 + subtitle 13 + 3 + waveform 18 + 4 bottom inset), and the
        // cell view is exactly one row tall — so at 56 Auto Layout had to take the missing 4pt
        // out of something, and it took them out of the duration line, which rendered at 9pt of
        // a 13pt label with its bottom sliced off (measured). The extra 2pt over the minimum is
        // slack for larger system text, and lands as bottom padding because everything in the
        // row hangs off its top edge.
        tableView.rowHeight = 62
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // Double-click renames in place, the same edit the right-click menu's Rename opens. Single
        // click keeps its existing job (select the clip and load it into the deck).
        tableView.doubleAction = #selector(renameClickedRow)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        Layout.pin(searchField, to: root, edges: [.top, .leading, .trailing], insets: NSEdgeInsets(top: 10, left: 10, bottom: 0, right: 10))
        Layout.pin(scrollView, to: root, edges: [.leading, .trailing, .bottom])
        scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8).isActive = true
    }

    func reloadClips() {
        allClips = libraryStore.all()
        applyFilter(preserveSelection: false)
    }

    func upsertClip(_ clip: PracticeClip) {
        if let index = allClips.firstIndex(where: { $0.id == clip.id }) {
            allClips[index] = clip
        } else {
            allClips.insert(clip, at: 0)
        }
        applyFilter(preserveSelection: true)
    }

    func selectClip(id: UUID) {
        guard let row = filteredClips.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func searchChanged() {
        applyFilter(preserveSelection: true)
    }

    private func applyFilter(preserveSelection: Bool) {
        let selectedID = preserveSelection && tableView.selectedRow >= 0 ? filteredClips[safe: tableView.selectedRow]?.id : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredClips = query.isEmpty
            ? allClips.sorted { $0.createdAt > $1.createdAt }
            : allClips.filter { $0.title.localizedCaseInsensitiveContains(query) }.sorted { $0.createdAt > $1.createdAt }
        tableView.reloadData()
        if let selectedID, let row = filteredClips.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filteredClips.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let clip = filteredClips[safe: row] else { return nil }
        let view = ClipRowView(clip: clip)
        view.onRenameCommitted = { [weak self] id, newTitle in
            self?.commitRename(clipID: id, newTitle: newTitle)
        }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let clip = filteredClips[safe: tableView.selectedRow] else { return }
        onSelectClip?(clip)
    }

    // MARK: - Rename

    /// Puts a row's title into edit mode. `makeIfNecessary: true`: a row that was scrolled out of
    /// view has no view yet, and asking for it is what materialises the one the table will use —
    /// with `false` the rename would silently do nothing there.
    func beginRenaming(clipID: UUID) {
        guard let row = filteredClips.firstIndex(where: { $0.id == clipID }) else { return }
        tableView.scrollRowToVisible(row)
        guard let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ClipRowView else { return }
        rowView.beginEditingTitle()
    }

    @objc private func renameClickedRow() {
        guard let clip = filteredClips[safe: tableView.clickedRow] else { return }
        beginRenaming(clipID: clip.id)
    }

    @objc private func renameMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        beginRenaming(clipID: id)
    }

    private func commitRename(clipID: UUID, newTitle: String) {
        guard let updated = libraryStore.rename(id: clipID, to: newTitle) else {
            // Blank/unchanged title: put the row back the way it was rather than persisting it.
            applyFilter(preserveSelection: true)
            return
        }
        upsertClip(updated)
        onRenameClip?(updated)
    }

    // MARK: - NSMenuDelegate

    /// Built per right-click rather than once up front: the item has to carry the id of the row
    /// that was actually clicked, and `clickedRow` is only meaningful while the click is being
    /// handled — not later, when the menu item fires.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let clip = filteredClips[safe: tableView.clickedRow] else { return }
        let item = NSMenuItem(title: "Rename…", action: #selector(renameMenuItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = clip.id
        menu.addItem(item)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Sidebar row: title, duration, processing state, and a small waveform thumbnail.
///
/// The title is a real `NSTextField` that flips between label and editor rather than a static
/// label, so renaming happens on the row itself (double-click, or Rename… from the row's context
/// menu) instead of in a separate dialog.
private final class ClipRowView: NSView, NSTextFieldDelegate {
    private let clipID: UUID
    private let titleField: NSTextField
    private var titleBeforeEditing: String
    private var isEditingTitle = false

    /// Called with the committed title. The sidebar owns persistence — the row only reports.
    var onRenameCommitted: ((UUID, String) -> Void)?

    init(clip: PracticeClip) {
        clipID = clip.id
        titleField = NSTextField(labelWithString: clip.title)
        titleBeforeEditing = clip.title
        super.init(frame: .zero)

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self
        titleField.cell?.usesSingleLineMode = true
        titleField.cell?.wraps = false
        titleField.cell?.isScrollable = true

        let subtitle = clip.processingFailed
            ? "Processing failed"
            : (clip.isFullyProcessed ? clip.durationSeconds.formattedAsDuration : "Processing… \(clip.readyDurationSeconds.formattedAsDuration) ready")
        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = .systemFont(ofSize: 10)
        subtitleField.textColor = clip.processingFailed ? .systemRed : .secondaryLabelColor
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        let waveform = WaveformView(style: .thumbnail)
        waveform.peaks = clip.waveformPeaks
        waveform.readyFraction = clip.durationSeconds > 0 ? CGFloat(clip.readyDurationSeconds / clip.durationSeconds) : 1
        waveform.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleField)
        addSubview(subtitleField)
        addSubview(waveform)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            subtitleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            subtitleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            waveform.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 3),
            waveform.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            waveform.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            waveform.heightAnchor.constraint(equalToConstant: 18),
            waveform.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Inline rename

    func beginEditingTitle() {
        guard !isEditingTitle, let window else { return }
        isEditingTitle = true
        titleBeforeEditing = titleField.stringValue
        titleField.isEditable = true
        titleField.isSelectable = true
        // Background + focus ring, deliberately *not* `isBezeled`: a bezel adds ~7pt to the
        // field's intrinsic height, which in a row this tight pushes the duration line down and
        // paints over it (seen in an offscreen render of the editing state). Painting the text
        // background leaves the field exactly as tall as it was.
        titleField.drawsBackground = true
        titleField.backgroundColor = .textBackgroundColor
        titleField.focusRingType = .default
        window.makeFirstResponder(titleField)
        // The field editor's automatic completion claims the first Escape and turns it into a
        // completion request, which is how a rename ends up with no way out. See also the
        // `complete(_:)` case below.
        (titleField.currentEditor() as? NSTextView)?.isAutomaticTextCompletionEnabled = false
        titleField.currentEditor()?.selectAll(nil)
    }

    /// Restores the label look. Leaving the field editable would let a stray click land a cursor
    /// in a row the user only meant to select.
    private func endEditingTitle() {
        isEditingTitle = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        if titleField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditingTitle else { return }
        let newTitle = titleField.stringValue
        endEditingTitle()
        guard newTitle != titleBeforeEditing else { return }
        // Async: the commit reloads the table, which tears this very view down — not something to
        // do from inside the text field's own end-editing notification.
        DispatchQueue.main.async { [clipID, onRenameCommitted] in
            onRenameCommitted?(clipID, newTitle)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSStandardKeyBindingResponding.complete(_:)):
            titleField.stringValue = titleBeforeEditing
            endEditingTitle()
            return true
        default:
            return false
        }
    }
}
