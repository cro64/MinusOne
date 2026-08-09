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
        guard itemIdentifier == Self.importItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Import"
        item.paletteLabel = "Import Clip"
        item.toolTip = "Import an audio file"
        item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
        item.target = self
        item.action = #selector(importButtonClicked)
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItemIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItemIdentifier, .flexibleSpace]
    }

    @objc private func importButtonClicked() {
        importService.presentOpenPanel(in: window) { [weak self] url in
            guard let self, let url else { return }
            self.handleImport(url: url)
        }
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
