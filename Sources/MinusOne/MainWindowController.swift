import AppKit

/// Owns the desktop window: a Live / Practice segmented switch in the title bar, and the two
/// tabs' content. Live embeds the existing `SettingsPopoverViewController`; Practice embeds the
/// existing sidebar + deck split view — both reused as-is per REDESIGN.md §1, not rebuilt.
///
/// Activation policy (REDESIGN.md §1): opening the window promotes the app to `.regular` with a
/// Dock icon; closing (red traffic light / ⌘W) demotes back to `.accessory` without quitting —
/// Live/Recording keep running. Only Quit in the menu bar popover fully quits.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Tab: Int {
        case live = 0
        case practice = 1
    }

    private let preferences: Preferences
    private let audioEngine: AudioEngine

    private let liveViewController: SettingsPopoverViewController
    private let practiceSplitViewController: PracticeSplitViewController
    private let sidebar: ClipSidebarViewController
    private let deck: PracticeDeckViewController
    private let importService: ClipImportService

    private let contentContainer = NSView()
    private let segmentedControl = NSSegmentedControl()
    private let liveStatusDot = NSView()
    private var currentTab: Tab = .live
    private var onboardingViewController: OnboardingViewController?

    private static let importItemIdentifier = NSToolbarItem.Identifier("importClip")
    private static let recordItemIdentifier = NSToolbarItem.Identifier("recordClip")
    private let practiceToolbar = NSToolbar(identifier: "PracticeToolbar")
    private var systemAudioRecorderBox: Any?
    private var recordingPopover: NSPopover?
    private weak var recordToolbarButton: NSButton?

    var onWindowClosed: (() -> Void)?

    init(
        preferences: Preferences,
        audioEngine: AudioEngine,
        libraryStore: ClipLibraryStore,
        importService: ClipImportService,
        playbackEngine: PracticePlaybackEngine
    ) {
        self.preferences = preferences
        self.audioEngine = audioEngine
        self.importService = importService
        liveViewController = SettingsPopoverViewController(preferences: preferences, audioEngine: audioEngine)
        sidebar = ClipSidebarViewController(libraryStore: libraryStore)
        deck = PracticeDeckViewController(libraryStore: libraryStore, playbackEngine: playbackEngine)
        practiceSplitViewController = PracticeSplitViewController(sidebar: sidebar, detail: deck)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MinusOne"
        window.minSize = NSSize(width: 760, height: 480)
        window.center()

        super.init(window: window)
        window.delegate = self

        let root = NSViewController()
        root.view = contentContainer
        window.contentViewController = root

        configureTitleBarAccessory()
        configureLiveTab()
        configurePracticeTab()

        sidebar.onSelectClip = { [weak self] clip in self?.deck.show(clip: clip) }
        sidebar.onDropFiles = { [weak self] urls in
            urls.forEach { self?.handleImport(url: $0) }
        }
        sidebar.reloadClips()

        if !presentOnboardingIfNeeded() {
            showTab(.live)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: Tab = .live) {
        showTab(tab)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLiveStatus(_ status: AudioEngineStatus, isFilterActive: Bool) {
        liveViewController.updateStatusDisplay(status, isFilterActive: isFilterActive)
        liveStatusDot.layer?.backgroundColor = (isFilterActive ? NSColor.brandAccent : NSColor.tertiaryLabelColor).cgColor
        liveStatusDot.isHidden = currentTab != .practice
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onboardingViewController?.handleWindowShouldClose() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    // MARK: - Onboarding

    /// First launch (REDESIGN.md §5): the window opens directly into onboarding instead of the
    /// Live/Practice tabs, since the Neural model download is now mandatory-framed rather than a
    /// skippable step. Returns `true` if onboarding content was shown.
    @discardableResult
    private func presentOnboardingIfNeeded() -> Bool {
        guard !preferences.hasCompletedOnboarding else { return false }

        let onboarding = OnboardingController.makeViewController(preferences: preferences) { [weak self] _ in
            self?.finishOnboarding()
        }
        onboardingViewController = onboarding
        segmentedControl.isHidden = true
        liveStatusDot.isHidden = true
        window?.toolbar = nil

        let content = onboarding.view
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        return true
    }

    private func finishOnboarding() {
        onboardingViewController?.view.removeFromSuperview()
        onboardingViewController = nil
        segmentedControl.isHidden = false
        liveViewController.reloadFromPreferences()
        showTab(.live)
    }

    /// Reflects a clip recorded (or still separating) via the menu bar's Record toggle into the
    /// Practice sidebar immediately, without requiring a reopen of the window.
    func clipImported(_ clip: PracticeClip) {
        sidebar.upsertClip(clip)
    }

    // MARK: - Title bar accessory

    private func configureTitleBarAccessory() {
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.segmentCount = 2
        segmentedControl.setLabel("Live", forSegment: Tab.live.rawValue)
        segmentedControl.setLabel("Practice", forSegment: Tab.practice.rawValue)
        segmentedControl.selectedSegment = Tab.live.rawValue
        segmentedControl.target = self
        segmentedControl.action = #selector(tabChanged)

        liveStatusDot.wantsLayer = true
        liveStatusDot.layer?.cornerRadius = 4
        liveStatusDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        liveStatusDot.isHidden = true
        liveStatusDot.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [liveStatusDot, segmentedControl])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            liveStatusDot.widthAnchor.constraint(equalToConstant: 8),
            liveStatusDot.heightAnchor.constraint(equalToConstant: 8)
        ])

        let accessoryViewController = NSTitlebarAccessoryViewController()
        accessoryViewController.view = stack
        accessoryViewController.layoutAttribute = .right
        window?.addTitlebarAccessoryViewController(accessoryViewController)
    }

    @objc private func tabChanged() {
        guard let tab = Tab(rawValue: segmentedControl.selectedSegment) else { return }
        showTab(tab)
    }

    private func showTab(_ tab: Tab) {
        currentTab = tab
        segmentedControl.selectedSegment = tab.rawValue
        liveStatusDot.isHidden = tab != .practice
        window?.toolbar = (tab == .practice) ? practiceToolbar : nil

        for child in contentContainer.subviews { child.removeFromSuperview() }
        let content: NSView
        switch tab {
        case .live:
            liveViewController.reloadFromPreferences()
            content = liveEmbeddingContainer
        case .practice:
            content = practiceSplitViewController.view
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    // MARK: - Live tab

    // `SettingsPopoverViewController` builds a fixed-size, shadowed popover panel — not a
    // window-filling view. Wrapping it unmodified in a flexible container is the minimum
    // structural change for this pass; a proper full-width Live tab layout is REDESIGN.md §3,
    // deferred.
    private lazy var liveEmbeddingContainer: NSView = {
        let container = NSView()
        let inner = liveViewController.view
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: 24)
        ])
        return container
    }()

    private func configureLiveTab() {
        _ = liveViewController.view
        liveViewController.reloadFromPreferences()
    }

    // MARK: - Practice tab

    private func configurePracticeTab() {
        practiceToolbar.delegate = self
        practiceToolbar.displayMode = .iconAndLabel

        deck.onImportRequested = { [weak self] in self?.importButtonClicked() }
        deck.onRecordRequested = { [weak self] in
            guard let self, let button = self.recordToolbarButton else { return }
            self.recordButtonClicked(button)
        }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.importItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = PopoverUI.toolbarActionButton(title: "Import", symbolName: "square.and.arrow.down", target: self, action: #selector(importButtonClicked))
            item.label = "Import"
            item.paletteLabel = "Import Clip"
            item.toolTip = "Import an audio file"
            item.view = button
            return item

        case Self.recordItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = PopoverUI.toolbarActionButton(title: "Record", symbolName: "record.circle", target: self, action: #selector(recordButtonClicked(_:)))
            item.label = "Record"
            item.paletteLabel = "Record System Audio"
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
