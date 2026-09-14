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
    private let scrollView = NSScrollView()
    private var allClips: [PracticeClip] = []
    private var filteredClips: [PracticeClip] = []
    private var playingClipID: UUID?

    /// Icon-only: a labelled pair costs ~180pt of a sidebar that can be dragged to 220pt wide,
    /// which would leave no usable search field. `setIcon` carries the dropped titles into the
    /// tooltip and the accessibility name.
    let importButton = FlatButton(title: "", kind: .ghost, target: nil, action: nil)
    let recordButton = FlatButton(title: "", kind: .ghost, target: nil, action: nil)

    /// Running elapsed readout, shown only while a take is in flight, in place of the search
    /// field. Clicking it returns to the Record page — leaving that page doesn't stop the take,
    /// so there has to be a way forward again.
    /// Constrained to the same 24pt as `importButton`/`recordButton`/`searchField`: `WindowUI.linkButton`
    /// returns a titled `FlatButton`, and `FlatButton.intrinsicContentSize` adds 8pt of vertical
    /// padding to *titled* buttons (the icon-only header buttons skip that branch), which otherwise
    /// makes this 30pt tall against the row's 24pt — measured as a 6pt jump in the scroll view's
    /// position every time a recording starts or stops, since the scroll view is pinned to the
    /// header's bottom.
    private let elapsedButton = WindowUI.linkButton(title: "")

    var onSelectClip: ((PracticeClip) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    /// Fired after a rename has been persisted, so the deck showing the same clip re-titles too.
    var onRenameClip: ((PracticeClip) -> Void)?
    var onImportClicked: (() -> Void)?
    var onRecordClicked: (() -> Void)?
    var onRecordElapsedClicked: (() -> Void)?

    var elapsedButtonForTesting: FlatButton { elapsedButton }
    var scrollViewForTesting: NSScrollView { scrollView }

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

        // Solid, not an `NSVisualEffectView` with the `.sidebar` material. That material blends
        // `.behindWindow`, so the library pane sampled the desktop through the window while every
        // other surface in the app paints an opaque `windowBackgroundColor` — the sidebar was the
        // one translucent area on screen. Matching the window fill keeps it continuous with the
        // deck beside it; the split view's divider is what separates the two panes.
        //
        // `ThemedView`, not a bare `layer.backgroundColor` write: `windowBackgroundColor` resolves
        // per-appearance, and a `cgColor` captured once freezes at whatever appearance was current
        // (see `Appearance.swift`).
        Layout.pin(ThemedView(fill: .windowBackgroundColor), to: root)

        searchField.placeholderString = "Search clips"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Ghost, not `.secondary`: `refreshStyle` only consults `textColorOverride` on the ghost
        // branch, so a coral Record glyph would otherwise mean changing shared `FlatButton`
        // behaviour. Ghost also reads quieter beside the bordered search field — these two
        // actions should not out-weigh the list they sit above. Same recipe as the title bar's
        // `backButton`/`appearanceButton`.
        for button in [importButton, recordButton] {
            button.cornerStyle = .capsule
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.constrainSize(width: 24, height: 24)
            button.target = self
        }
        importButton.textColorOverride = .secondaryLabelColor
        importButton.setIcon("square.and.arrow.down", pointSize: 12, label: "Import")
        importButton.action = #selector(importClicked)
        // No `textColorOverride`: ghost's default tint is `.brandAccent`, and Record is the one
        // place in this pane that spends the accent.
        recordButton.setIcon("record.circle", pointSize: 12, label: "Record")
        recordButton.action = #selector(recordClicked)

        elapsedButton.isHidden = true
        elapsedButton.textColorOverride = .brandAccentDeep
        // A running time reads as a label, so its one affordance is spelled out rather than left
        // to be discovered by clicking.
        elapsedButton.toolTip = "Back to the recording"
        elapsedButton.setAccessibilityLabel("Back to the recording")
        elapsedButton.target = self
        elapsedButton.action = #selector(recordElapsedClicked)
        elapsedButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

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
        // `.inset`, not `.sourceList`. The source-list style is where the pane's translucency
        // actually came from: AppKit installs its own `NSVisualEffectView` (material `.sidebar`,
        // blending `.behindWindow` — read back off the live view hierarchy) inside the enclosing
        // scroll view, so the desktop showed through the clip list while every other surface in
        // the app is an opaque `windowBackgroundColor`. Nothing painted *behind* the table can fix
        // that, since behind-window blending samples past the window entirely. `.inset` keeps the
        // same inset, rounded row selection without the vibrancy.
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // Double-click renames in place, the same edit the right-click menu's Rename opens. Single
        // click keeps its existing job (select the clip and load it into the deck).
        tableView.doubleAction = #selector(renameClickedRow)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let header = Layout.horizontalStack([importButton, recordButton, searchField, elapsedButton], spacing: 6)
        Layout.pin(header, to: root, edges: [.top, .leading, .trailing], insets: NSEdgeInsets(top: 10, left: 10, bottom: 0, right: 10))
        Layout.pin(scrollView, to: root, edges: [.leading, .trailing, .bottom])
        scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8).isActive = true
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

    /// Reflects the deck's play state onto the row of whichever clip is (or was) playing.
    ///
    /// Updates only the two rows that can actually change — the previously-playing one and the
    /// newly-playing one — rather than `reloadData()`, which would tear down and rebuild every
    /// visible `ClipRowView` (dropping in-place rename state) on every play/pause/clip-switch tick.
    func setPlayingClip(id: UUID?) {
        guard id != playingClipID else { return }
        let previousID = playingClipID
        playingClipID = id
        for changedID in [previousID, id] {
            guard let changedID, let row = filteredClips.firstIndex(where: { $0.id == changedID }) else { continue }
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipRowView)?
                .setPlaying(changedID == playingClipID)
        }
    }

    @objc private func searchChanged() {
        applyFilter(preserveSelection: true)
    }

    @objc private func importClicked() { onImportClicked?() }

    @objc private func recordClicked() { onRecordClicked?() }

    /// Reflects the shared recorder's state in the header. A recording started from the Record
    /// page (or the menu bar) keeps running after you navigate back here, so Record has to become
    /// the way to stop it — otherwise the only stop control is on a page you've left.
    func setRecordingState(_ recording: Bool) {
        recordButton.setIcon(
            recording ? "stop.fill" : "record.circle",
            pointSize: 12,
            label: recording ? "Stop" : "Record"
        )
        elapsedButton.isHidden = !recording
        // Hidden rather than removed: the query is still in the field when the take ends.
        searchField.isHidden = recording
        // Seeded rather than left blank until the first progress tick ~100ms later, which would
        // otherwise show an empty button for a frame.
        elapsedButton.title = recording ? "●  0:00" : ""
    }

    func updateRecordingElapsed(_ seconds: Double) {
        guard !elapsedButton.isHidden else { return }
        elapsedButton.title = "●  \(seconds.formattedAsDuration)"
    }

    @objc private func recordElapsedClicked() { onRecordElapsedClicked?() }

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
        let view = ClipRowView(clip: clip, isPlaying: clip.id == playingClipID)
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

    var searchFieldForTesting: NSSearchField { searchField }
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
    private let nowPlayingIcon = NSImageView()
    private var titleBeforeEditing: String
    private var isEditingTitle = false

    /// Called with the committed title. The sidebar owns persistence — the row only reports.
    var onRenameCommitted: ((UUID, String) -> Void)?

    init(clip: PracticeClip, isPlaying: Bool) {
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

        // Trailing glyph rather than a background/border on the whole row: the row already
        // conveys selection via the table's own selection highlight, so "playing" needs a signal
        // that reads independently of — and survives scrolling past — that selection state.
        nowPlayingIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        nowPlayingIcon.contentTintColor = .brandAccentDeep
        nowPlayingIcon.imageScaling = .scaleProportionallyUpOrDown
        nowPlayingIcon.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingIcon.setContentHuggingPriority(.required, for: .horizontal)
        // Explicit, not left to intrinsic content size: `speaker.wave.2.fill`'s drawn wave arcs
        // extend past the symbol's reported intrinsic width at this point size, so an
        // intrinsically-sized `NSImageView` clipped the outer arc (measured in an offscreen
        // render — visibly cut mid-arc). A frame a few points wider than that intrinsic size
        // gives the glyph room to draw in full.
        nowPlayingIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        nowPlayingIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let subtitle = clip.processingFailed
            ? "Processing failed"
            : (clip.isFullyProcessed ? clip.durationSeconds.formattedAsDuration : "Processing… \(clip.readyDurationSeconds.formattedAsDuration) ready")
        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = .systemFont(ofSize: 10)
        subtitleField.textColor = clip.processingFailed ? .systemRed : .secondaryLabelColor
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        let waveform = WaveformView()
        waveform.peaks = clip.waveformPeaks
        waveform.readyFraction = clip.durationSeconds > 0 ? CGFloat(clip.readyDurationSeconds / clip.durationSeconds) : 1
        waveform.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleField)
        addSubview(nowPlayingIcon)
        addSubview(subtitleField)
        addSubview(waveform)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: nowPlayingIcon.leadingAnchor, constant: -4),

            nowPlayingIcon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            nowPlayingIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            subtitleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            subtitleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            waveform.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 3),
            waveform.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            waveform.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            waveform.heightAnchor.constraint(equalToConstant: 18),
            waveform.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])

        setPlaying(isPlaying)
    }

    /// Toggles the trailing "now playing" glyph. Called both at row creation (from the sidebar's
    /// currently-tracked `playingClipID`) and afterwards as playback state changes, so a row
    /// scrolled into view mid-playback still shows the right state without a full table reload.
    func setPlaying(_ isPlaying: Bool) {
        nowPlayingIcon.isHidden = !isPlaying
        titleField.textColor = isPlaying ? .brandAccentDeep : .labelColor
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
