import AppKit

/// `NSTitlebarAccessoryViewController`'s clip view reserves title-bar space from the accessory
/// view's `intrinsicContentSize`, not from constraints on an arbitrary child (an `NSStackView`
/// with only constraint-based sizing measured as zero-width at title-bar layout time even with
/// its children fully constrained). Overriding this directly is the documented, reliable fix.
private final class TitlebarAccessoryContainerView: NSView {
    var fixedSize: NSSize = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { fixedSize }
}

/// Owns the desktop window: a Live / Practice segmented switch in the title bar, and the two
/// tabs' content. Live embeds `LiveTabViewController`, a full-width window-filling view (REDESIGN.md
/// §3); Practice embeds the existing sidebar + deck split view, reused as-is per REDESIGN.md §1.
///
/// Activation policy (REDESIGN.md §1): opening the window promotes the app to `.regular` with a
/// Dock icon; closing (red traffic light / ⌘W) demotes back to `.accessory` without quitting —
/// Live/Recording keep running. Only Quit in the menu bar popover fully quits.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int {
        case live = 0
        case practice = 1
    }

    private let preferences: Preferences
    private let audioEngine: AudioEngine

    private let liveViewController: LiveTabViewController
    private let practiceSplitViewController: PracticeSplitViewController
    private let sidebar: ClipSidebarViewController
    private let deck: PracticeDeckViewController
    private let importService: ClipImportService

    private let contentContainer = NSView()
    private let segmentedControl = FlatSegmentedControl(titles: ["Live", "Practice"])
    private let liveStatusDot = NSView()
    private var currentTab: Tab = .live
    private var onboardingViewController: OnboardingViewController?

    // Practice's Import/Record actions live in the tab's own content, not the window's title-bar
    // toolbar — a native toolbar button reads oversized/out-of-place at this button style's scale;
    // this is real window content per the flat/branded surface, not title-bar chrome.
    private let importActionButton = PopoverUI.toolbarActionButton(title: "Import", symbolName: "square.and.arrow.down", target: nil, action: nil)
    private let recordActionButton = PopoverUI.toolbarActionButton(title: "Record", symbolName: "record.circle", target: nil, action: nil)
    private var systemAudioRecorderBox: Any?
    private var recordingPopover: NSPopover?

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
        liveViewController = LiveTabViewController(preferences: preferences, audioEngine: audioEngine)
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
        // Explicit, not just relying on NSWindow's defaults: an ambiguous/false isOpaque or clear
        // backgroundColor is exactly what makes the Dock show through the window at the edges.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.center()

        super.init(window: window)
        window.delegate = self

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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
        liveStatusDot.layer?.backgroundColor = (isFilterActive ? NSColor.brandAccentDeep : NSColor.tertiaryLabelColor).cgColor
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
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let segmentedSize = segmentedControl.fittingSize
        let segmentedWidth = max(segmentedSize.width, 120)
        // 26, not 20: a pill this short reads as squat rather than capsule-shaped.
        let segmentedHeight = max(segmentedSize.height, 26)
        let stackWidth = stack.edgeInsets.left + 8 + stack.spacing + segmentedWidth + stack.edgeInsets.right
        let stackHeight = segmentedHeight + stack.edgeInsets.top + stack.edgeInsets.bottom
        NSLayoutConstraint.activate([
            liveStatusDot.widthAnchor.constraint(equalToConstant: 8),
            liveStatusDot.heightAnchor.constraint(equalToConstant: 8),
            segmentedControl.widthAnchor.constraint(equalToConstant: segmentedWidth),
            segmentedControl.heightAnchor.constraint(equalToConstant: segmentedHeight),
            stack.widthAnchor.constraint(equalToConstant: stackWidth),
            stack.heightAnchor.constraint(equalToConstant: stackHeight)
        ])

        let container = TitlebarAccessoryContainerView()
        container.fixedSize = NSSize(width: stackWidth, height: stackHeight)
        container.setFrameSize(container.fixedSize)
        // `intrinsicContentSize` is only consulted by Auto Layout's content-hugging/compression
        // machinery when the view itself participates in constraint-based layout — leaving the
        // default `true` here means AppKit derives the container's size from its (empty, .zero)
        // autoresizing frame instead of the override above.
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let accessoryViewController = NSTitlebarAccessoryViewController()
        accessoryViewController.view = container
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

        for child in contentContainer.subviews { child.removeFromSuperview() }
        let content: NSView
        switch tab {
        case .live:
            liveViewController.reloadFromPreferences()
            content = liveViewController.view
        case .practice:
            content = practiceContainer
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

    private func configureLiveTab() {
        _ = liveViewController.view
        liveViewController.reloadFromPreferences()
    }

    // MARK: - Practice tab

    /// Import/Record action row above the sidebar + deck split, at `Regular` scale like the rest
    /// of the window's content.
    private lazy var practiceContainer: NSView = {
        let actionRow = NSStackView(views: [importActionButton, recordActionButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = PopoverUI.Metrics.Regular.rowSpacing
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let splitView = practiceSplitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(actionRow)
        container.addSubview(splitView)

        let pad = PopoverUI.Metrics.Regular.padding
        NSLayoutConstraint.activate([
            actionRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            actionRow.topAnchor.constraint(equalTo: container.topAnchor, constant: PopoverUI.Metrics.Regular.rowSpacing),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            splitView.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: PopoverUI.Metrics.Regular.rowSpacing)
        ])
        return container
    }()

    private func configurePracticeTab() {
        importActionButton.target = self
        importActionButton.action = #selector(importButtonClicked)
        recordActionButton.target = self
        recordActionButton.action = #selector(recordButtonClicked(_:))
        if #unavailable(macOS 14.2) {
            recordActionButton.isEnabled = false
            recordActionButton.toolTip = "Recording system audio requires macOS 14.2 or later"
        }

        deck.onImportRequested = { [weak self] in self?.importButtonClicked() }
        deck.onRecordRequested = { [weak self] in
            guard let self else { return }
            self.recordButtonClicked(self.recordActionButton)
        }
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
        let anchorView = (sender as? NSView) ?? recordActionButton

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
