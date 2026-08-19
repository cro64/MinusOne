import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var audioEngine = AudioEngine(preferences: preferences)
    private var menuBarController: MenuBarController?
    private var deviceMonitor: DeviceMonitor?
    private var hotKeyController: HotKeyController?
    private var restartAfterWake = false
    private var wasReductionEnabledBeforeSleep = false
    private var deviceRebuildWorkItem: DispatchWorkItem?

    private let practiceLibraryStore = ClipLibraryStore()
    private lazy var practiceSeparationEngine = OfflineSeparationEngine(libraryStore: practiceLibraryStore)
    private lazy var practiceImportService = ClipImportService(libraryStore: practiceLibraryStore, separationEngine: practiceSeparationEngine)
    private lazy var practicePlaybackEngine = PracticePlaybackEngine()
    private var mainWindowController: MainWindowController?

    /// One recorder for the whole app. The menu bar's Record toggle and the window's Record page
    /// used to build one each, which was harmless only while the window's copy lived inside a
    /// transient popover that nothing else observed. Now that the Practice toolbar shows a Stop
    /// button for whatever recording is in flight, two recorders would mean a menu-bar-started
    /// take is invisible to the window — and that both could run against the same aggregate device
    /// at once. `Any?` because a stored property can't carry `@available`.
    private var clipRecorderBox: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window or the menu bar item is built, so nothing gets one frame of the wrong
        // appearance (and, more importantly, so no layer color is resolved against it).
        preferences.appearance.apply()

        // Standard editing shortcuts are menu key equivalents, so without this ⌘A/⌘C/⌘V/⌘X/⌘Z do
        // nothing anywhere in the app — see `AppMenu`.
        AppMenu.install()

        if #available(macOS 14.2, *) {
            ProcessTapSession.destroyStaleAggregates()
        }
        audioEngine.recoverOrphanedBlackHoleIfNeeded()

        menuBarController = MenuBarController(
            preferences: preferences,
            audioEngine: audioEngine,
            importService: practiceImportService
        )
        if #available(macOS 14.2, *) {
            menuBarController?.attachRecorder(clipRecorder)
            configureRecorderFanOut()
        }
        audioEngine.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.menuBarController?.updateStatus(status)
            self.mainWindowController?.updateLiveStatus(status, isFilterActive: self.audioEngine.isVocalReductionActive)
        }
        menuBarController?.onOpenPracticeMode = { [weak self] in
            self?.openMainWindow(tab: .live)
        }
        menuBarController?.onClipRecorded = { [weak self] clip in
            self?.mainWindowController?.clipImported(clip)
        }

        deviceMonitor = DeviceMonitor(
            onDeviceChange: { [weak self] in
                guard let self else { return }
                deviceRebuildWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self, audioEngine.isRunning else { return }
                    audioEngine.scheduleRebuildForDeviceChange()
                }
                deviceRebuildWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
            },
            onWillSleep: { [weak self] in
                guard let self else { return }
                restartAfterWake = audioEngine.isRunning
                wasReductionEnabledBeforeSleep = audioEngine.isReductionEnabled
                audioEngine.stop(restoreOutput: true)
            },
            onDidWake: { [weak self] in
                guard let self, restartAfterWake else { return }
                restartAfterWake = false
                let shouldRestoreReduction = wasReductionEnabledBeforeSleep
                wasReductionEnabledBeforeSleep = false
                audioEngine.start { [weak self] success in
                    guard let self, success, shouldRestoreReduction else { return }
                    self.audioEngine.enableReduction()
                }
            }
        )
        deviceMonitor?.start()

        hotKeyController = HotKeyController { [weak self] in
            guard let self else { return }
            menuBarController?.performToggleWithOnboarding()
        }
        hotKeyController?.registerDefaultHotKey()

        menuBarController?.updateStatus(.idle)
        AppLogger.shared.info("MinusOne launched")

        // REDESIGN.md §5: onboarding — including the now-mandatory Neural model download — opens
        // directly in the window on first launch, not the menu bar.
        if !preferences.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.openMainWindow(tab: .live)
            }
        }

        // Test-only: opens straight to the window/tab named, bypassing the menu-bar-click flow
        // entirely. That flow is a real, separately-flaky thing to test (display-arrangement
        // dependent, see MinusOneUITests' openMainWindow() comment) — this exists so layout tests
        // for a *specific tab* aren't gated on it too.
        if let tabName = ProcessInfo.processInfo.environment["MINUSONE_UI_TEST_OPEN_WINDOW"] {
            let tab: MainWindowController.Tab = tabName == "practice" ? .practice : .live
            DispatchQueue.main.async { [weak self] in
                self?.openMainWindow(tab: tab)
            }
        }

        restoreSessionIfNeeded()
    }

    @available(macOS 14.2, *)
    private var clipRecorder: ClipRecorder {
        if let existing = clipRecorderBox as? ClipRecorder { return existing }
        let recorder = ClipRecorder()
        clipRecorderBox = recorder
        return recorder
    }

    /// Both recorder callbacks are single-assignment closures, so they're claimed once here and
    /// forwarded, rather than being re-assigned by whichever surface happens to appear last.
    /// The window is built lazily and torn down on close, so these have to survive it not existing.
    @available(macOS 14.2, *)
    private func configureRecorderFanOut() {
        clipRecorder.onRecordingStateChanged = { [weak self] isRecording in
            guard let self else { return }
            self.menuBarController?.updateRecordingState(isRecording)
            self.mainWindowController?.updateRecordingState(isRecording)
        }
        clipRecorder.onProgress = { [weak self] peaks, elapsed in
            self?.mainWindowController?.updateRecordingProgress(peaks: peaks, elapsed: elapsed)
        }
    }

    private func openMainWindow(tab: MainWindowController.Tab) {
        if mainWindowController == nil {
            let controller = MainWindowController(
                preferences: preferences,
                audioEngine: audioEngine,
                libraryStore: practiceLibraryStore,
                importService: practiceImportService,
                playbackEngine: practicePlaybackEngine
            )
            if #available(macOS 14.2, *) {
                controller.attachRecorder(clipRecorder)
            }
            controller.onWindowClosed = { [weak self] in
                NSApp.setActivationPolicy(.accessory)
                self?.mainWindowController = nil
            }
            mainWindowController = controller
        }
        NSApp.setActivationPolicy(.regular)
        mainWindowController?.show(tab: tab)
        mainWindowController?.updateLiveStatus(audioEngine.status, isFilterActive: audioEngine.isVocalReductionActive)
    }

    private func restoreSessionIfNeeded() {
        guard preferences.lastReductionEnabled else { return }

        audioEngine.start { [weak self] success in
            guard let self, success else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.audioEngine.enableReduction()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController?.unregister()
        deviceMonitor?.stop()
        audioEngine.stop(restoreOutput: true)
        AppLogger.shared.info("MinusOne terminated")
    }
}
