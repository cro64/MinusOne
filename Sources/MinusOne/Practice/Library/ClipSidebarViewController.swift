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

final class ClipSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let libraryStore: ClipLibraryStore
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private var allClips: [PracticeClip] = []
    private var filteredClips: [PracticeClip] = []

    var onSelectClip: ((PracticeClip) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

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
        tableView.rowHeight = 56
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = nil

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
        return ClipRowView(clip: clip)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let clip = filteredClips[safe: tableView.selectedRow] else { return }
        onSelectClip?(clip)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Sidebar row: title, duration, processing state, and a small waveform thumbnail.
private final class ClipRowView: NSView {
    init(clip: PracticeClip) {
        super.init(frame: .zero)

        let titleField = NSTextField(labelWithString: clip.title)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

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

}
