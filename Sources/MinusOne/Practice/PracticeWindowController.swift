import AppKit

/// Owns the Practice Mode window: sidebar library + practice deck, wired to the shared
/// library store, offline separation engine, and playback engine.
final class PracticeWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let libraryStore: ClipLibraryStore
    private let importService: ClipImportService
    private let playbackEngine: PracticePlaybackEngine
    private let sidebar: ClipSidebarViewController
    private let deck: PracticeDeckViewController

    var onWindowClosed: (() -> Void)?

    private static let importItemIdentifier = NSToolbarItem.Identifier("importClip")
    private static let recordItemIdentifier = NSToolbarItem.Identifier("recordClip")

    private var systemAudioRecorderBox: Any?
    private var recordingPopover: NSPopover?
    private weak var recordToolbarButton: NSButton?

    init(
        libraryStore: ClipLibraryStore,
        importService: ClipImportService,
        playbackEngine: PracticePlaybackEngine
    ) {
        self.libraryStore = libraryStore
        self.importService = importService
        self.playbackEngine = playbackEngine
        sidebar = ClipSidebarViewController(libraryStore: libraryStore)
        deck = PracticeDeckViewController(libraryStore: libraryStore, playbackEngine: playbackEngine)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MinusOne — Practice"
        window.minSize = NSSize(width: 760, height: 480)
        window.center()

        super.init(window: window)
        window.delegate = self

        let splitViewController = PracticeSplitViewController(sidebar: sidebar, detail: deck)
        window.contentViewController = splitViewController

        configureToolbar()
        sidebar.onSelectClip = { [weak self] clip in self?.deck.show(clip: clip) }
        sidebar.onDropFiles = { [weak self] urls in
            urls.forEach { self?.handleImport(url: $0) }
        }
        sidebar.reloadClips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    // MARK: - Toolbar

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "PracticeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.importItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Import"
            item.paletteLabel = "Import Clip"
            item.toolTip = "Import an audio file"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
            item.target = self
            item.action = #selector(importButtonClicked)
            return item

        case Self.recordItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Record"
            item.paletteLabel = "Record System Audio"

            // Custom-view button (not item.target/action) so the popover has a stable, guaranteed
            // NSView to anchor to — standard toolbar items don't reliably pass a usable view as `sender`.
            let button = NSButton(
                image: NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record") ?? NSImage(),
                target: self,
                action: #selector(recordButtonClicked(_:))
            )
            button.bezelStyle = .texturedRounded
            button.imageScaling = .scaleProportionallyDown
            recordToolbarButton = button
            item.view = button

            if #available(macOS 14.2, *) {
                item.toolTip = "Record system audio"
                button.isEnabled = true
            } else {
                item.toolTip = "Recording system audio requires macOS 14.2 or later"
                button.isEnabled = false
            }
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItemIdentifier, Self.recordItemIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItemIdentifier, Self.recordItemIdentifier, .flexibleSpace]
    }

    @objc private func importButtonClicked() {
        importService.presentOpenPanel(in: window) { [weak self] url in
            guard let self, let url else { return }
            self.handleImport(url: url)
        }
    }

    @available(macOS 14.2, *)
    private var systemAudioRecorder: SystemAudioRecorder {
        if let existing = systemAudioRecorderBox as? SystemAudioRecorder { return existing }
        let recorder = SystemAudioRecorder()
        systemAudioRecorderBox = recorder
        return recorder
    }

    @objc private func recordButtonClicked(_ sender: Any) {
        guard #available(macOS 14.2, *) else { return }
        guard let anchorView = (sender as? NSView) ?? recordToolbarButton else {
            AppLogger.shared.warning("Practice record button clicked but no anchor view was available")
            return
        }

        let panel = RecordingPanelController(recorder: systemAudioRecorder) { [weak self] url in
            self?.handleImport(url: url)
            self?.recordingPopover?.performClose(nil)
        }
        let popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        recordingPopover = popover
    }

    private func handleImport(url: URL) {
        importService.importFile(
            at: url,
            onImported: { [weak self] clip in
                guard let self else { return }
                self.sidebar.upsertClip(clip)
                self.sidebar.selectClip(id: clip.id)
                self.deck.show(clip: clip)
            },
            onProgress: { [weak self] clip in
                guard let self else { return }
                self.sidebar.upsertClip(clip)
                self.deck.updateClip(clip)
            },
            onFailure: { [weak self] error in
                self?.presentImportError(error)
            }
        )
    }

    private func presentImportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't import this clip"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
