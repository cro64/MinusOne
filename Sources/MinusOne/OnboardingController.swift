import AppKit

/// Factory for the first-launch welcome + Neural model download screen. Per REDESIGN.md §5 this
/// renders inside `MainWindowController`'s window, not a standalone window — `OnboardingViewController`
/// is a plain content view controller MainWindowController swaps in until onboarding finishes.
enum OnboardingController {
    static func makeViewController(
        preferences: Preferences,
        onFinished: @escaping (Bool) -> Void
    ) -> OnboardingViewController {
        OnboardingViewController(preferences: preferences, onFinished: onFinished)
    }
}

/// First-launch welcome screen. The Neural model is mandatory for Live to do anything (REDESIGN.md
/// §5), so this no longer offers a "skip and use Center Cut" fallback — backing out just defers the
/// download, and the Live tab picks up the gap with its own model-required state.
final class OnboardingViewController: NSViewController {
    private let preferences: Preferences
    private let onFinished: (Bool) -> Void

    private let modelInfoButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton(title: "Download & Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Continue Without Downloading", target: nil, action: nil)
    private var modelInfoPopover: NSPopover?
    private var isBusy = false
    private var downloadTask: Task<Void, Never>?
    private var didFinish = false

    private let variant = SeparationModelVariant.balanced

    init(preferences: Preferences, onFinished: @escaping (Bool) -> Void) {
        self.preferences = preferences
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let size = NSSize(width: 420, height: 300)
        view = makeContentView(size: size)
    }

    /// Called by `MainWindowController` when the host window is about to close. Returns `true` to
    /// allow the close, `false` to keep it open (e.g. an in-flight download the user chose to keep).
    func handleWindowShouldClose() -> Bool {
        guard isBusy else {
            finish(downloaded: false)
            return true
        }
        return !confirmCancelDownload()
    }

    private func makeContentView(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))

        let logoImage = MinusOneIcon.waveform(size: 56, color: .brandAccent, isActive: true)
        let logoView = NSImageView(image: logoImage)
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logoView.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let name = NSTextField(labelWithString: "MinusOne")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        name.textColor = .labelColor
        name.alignment = .center

        let body = NSTextField(wrappingLabelWithString: """
        Live vocal reduction runs on the Neural model — there's no other processing path. Download it once (\(variant.approximateDownloadSizeText), about 20 seconds to prepare after downloading) and Live is ready whenever you are.
        """)
        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        configureModelInfoButton()

        let modelLabel = NSTextField(labelWithString: "Neural model · Demucs")
        modelLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        modelLabel.textColor = .secondaryLabelColor

        let modelHeaderSpacer = NSView()
        modelHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let modelHeader = NSStackView(views: [modelLabel, modelHeaderSpacer, modelInfoButton])
        modelHeader.orientation = .horizontal
        modelHeader.alignment = .centerY
        modelHeader.spacing = 4

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = defaultStatusText()
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.alignment = .center
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 12).isActive = true

        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = "\r"
        primaryButton.bezelStyle = .rounded

        skipButton.target = self
        skipButton.action = #selector(skipClicked)
        skipButton.bezelStyle = .rounded

        updatePrimaryButtonTitle()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, skipButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let header = NSStackView(views: [logoView, name])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 8

        let stack = NSStackView(views: [
            header, body, modelHeader, statusLabel, progress, buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: header)
        stack.setCustomSpacing(14, after: body)
        stack.setCustomSpacing(14, after: progress)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return root
    }

    private func configureModelInfoButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Model source info")?
            .withSymbolConfiguration(config)
        modelInfoButton.image = image
        modelInfoButton.imagePosition = .imageOnly
        modelInfoButton.isBordered = false
        modelInfoButton.bezelStyle = .inline
        modelInfoButton.contentTintColor = .secondaryLabelColor
        modelInfoButton.toolTip = "Where this model comes from"
        modelInfoButton.target = self
        modelInfoButton.action = #selector(showModelInfo)
        modelInfoButton.setContentHuggingPriority(.required, for: .horizontal)
        modelInfoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelInfoButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        modelInfoButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    private func defaultStatusText() -> String {
        if SeparationModelFactory.isAvailable(variant) {
            return "Already installed."
        }
        return "One-time download, \(variant.approximateDownloadSizeText), then ~20 s to prepare."
    }

    private func updatePrimaryButtonTitle() {
        primaryButton.title = SeparationModelFactory.isAvailable(variant)
            ? "Continue"
            : "Download & Continue"
    }

    @objc private func showModelInfo() {
        if let existing = modelInfoPopover, existing.isShown {
            existing.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = ModelSourceInfoViewController(
            variant: variant,
            onOpenSource: { [weak popover] url in
                NSWorkspace.shared.open(url)
                popover?.performClose(nil)
            }
        )
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        modelInfoPopover = popover
        popover.show(relativeTo: modelInfoButton.bounds, of: modelInfoButton, preferredEdge: .maxY)
    }

    @objc private func skipClicked() {
        if isBusy {
            _ = confirmCancelDownload()
            return
        }
        finish(downloaded: false)
    }

    @objc private func primaryClicked() {
        guard !isBusy else { return }
        preferences.separationModelVariant = variant

        if SeparationModelFactory.isAvailable(variant) {
            finish(downloaded: true)
            return
        }

        beginDownload()
    }

    /// Returns whether the download was actually canceled (so callers can decide whether to also
    /// close their host window).
    @discardableResult
    private func confirmCancelDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Cancel download?"
        alert.informativeText = "The Neural model isn't installed yet. Live vocal reduction won't work until you download it — you can pick this up again from the Live tab."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Cancel Download")
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return false }
        cancelDownload()
        return true
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        ModelDownloadService.cleanupStaging(for: variant)
        isBusy = false
        primaryButton.isEnabled = true
        skipButton.isEnabled = true
        skipButton.title = "Continue Without Downloading"
        progress.isHidden = true
        progress.doubleValue = 0
        statusLabel.stringValue = "Download canceled."
        statusLabel.textColor = .secondaryLabelColor
        updatePrimaryButtonTitle()
        AppLogger.shared.info("Onboarding model download canceled")
    }

    private func beginDownload() {
        isBusy = true
        primaryButton.isEnabled = false
        skipButton.isEnabled = true
        skipButton.title = "Cancel"
        progress.isHidden = false
        progress.doubleValue = 0
        statusLabel.textColor = .secondaryLabelColor

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await ModelDownloadService.install(self.variant) { [weak self] fraction, message in
                    self?.progress.doubleValue = fraction
                    self?.statusLabel.stringValue = message
                }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.downloadTask = nil
                    self.preferences.separationModelVariant = self.variant
                    self.statusLabel.stringValue = "Model installed. Live is ready."
                    self.statusLabel.textColor = .secondaryLabelColor
                    self.progress.doubleValue = 1
                    self.skipButton.title = "Continue Without Downloading"
                    self.finish(downloaded: true)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.isBusy {
                        self.cancelDownload()
                    }
                }
            } catch {
                await MainActor.run {
                    self.downloadTask = nil
                    self.isBusy = false
                    self.primaryButton.isEnabled = true
                    self.skipButton.isEnabled = true
                    self.skipButton.title = "Continue Without Downloading"
                    self.progress.isHidden = true
                    self.statusLabel.stringValue = error.localizedDescription
                    self.statusLabel.textColor = .systemRed
                    self.updatePrimaryButtonTitle()
                    AppLogger.shared.error("Onboarding model download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(downloaded: Bool) {
        guard !didFinish else { return }
        didFinish = true
        preferences.hasCompletedOnboarding = true
        if downloaded {
            AppLogger.shared.info("Onboarding completed with Neural model installed")
        } else {
            AppLogger.shared.info("Onboarding completed without model download")
        }
        modelInfoPopover?.performClose(nil)
        modelInfoPopover = nil
        isBusy = false
        downloadTask = nil
        onFinished(downloaded)
    }
}

/// Compact popover explaining where the Neural model comes from.
private final class ModelSourceInfoViewController: NSViewController {
    private let variant: SeparationModelVariant
    private let onOpenSource: (URL) -> Void

    init(variant: SeparationModelVariant, onOpenSource: @escaping (URL) -> Void) {
        self.variant = variant
        self.onOpenSource = onOpenSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: .zero)

        let title = NSTextField(labelWithString: variant.displayName)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.textColor = .labelColor

        let body = NSTextField(wrappingLabelWithString: variant.sourceAttributionText.trimmingCharacters(in: .whitespacesAndNewlines))
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 0

        var arranged: [NSView] = [title, body]
        if variant.sourcePageURL != nil {
            let link = NSButton(title: "View on Hugging Face", target: self, action: #selector(openSource))
            link.isBordered = false
            link.bezelStyle = .inline
            link.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            link.contentTintColor = .brandAccent
            link.alignment = .left
            arranged.append(link)
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        PopoverUI.pin(stack, to: root, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 252),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        view = root
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(
            width: 280,
            height: ceil(stack.fittingSize.height + 24)
        )
    }

    @objc private func openSource() {
        guard let url = variant.sourcePageURL else { return }
        onOpenSource(url)
    }
}
