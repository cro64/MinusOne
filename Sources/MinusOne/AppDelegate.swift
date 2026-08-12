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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 14.2, *) {
            ProcessTapSession.destroyStaleAggregates()
        }
        audioEngine.recoverOrphanedBlackHoleIfNeeded()

        menuBarController = MenuBarController(
            preferences: preferences,
            audioEngine: audioEngine,
            importService: practiceImportService
        )
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

    private func openMainWindow(tab: MainWindowController.Tab) {
        if mainWindowController == nil {
            let controller = MainWindowController(
                preferences: preferences,
                audioEngine: audioEngine,
                libraryStore: practiceLibraryStore,
                importService: practiceImportService,
                playbackEngine: practicePlaybackEngine
            )
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
