import AppKit
import Sparkle

/// The only file that talks to Sparkle. It owns the standard updater (Sparkle's own update window
/// and installer) and forwards what the app cares about to `UpdateController`.
///
/// Gentle reminders: a scheduled check that finds an update never opens a window. We return false
/// from `standardUserDriverShouldHandleShowingScheduledUpdate`, Sparkle tells us it won't show it,
/// and the menu bar badge takes over until the user looks at it.
final class SparkleUpdater: NSObject, UpdaterDriving, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var events: UpdateController?
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "none"
        AppLogger.shared.info("Updater started (feed: \(feed))")
    }

    // MARK: - UpdaterDriving

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// With a badged update waiting, this brings that update's window forward instead of checking again.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        events?.updateWillBeShown(version: update.displayVersionString, sparkleShowsIt: handleShowingUpdate)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        events?.userLookedAtUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        events?.updateSessionFinished()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        events?.shouldPostponeRelaunch(install: installHandler) ?? false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        events?.updateFound(version: item.displayVersionString)
    }

    /// Fires after every check, scheduled or manual. A daily scheduled check that simply finds
    /// nothing new (`SUNoUpdateError`, code 1001) is the normal case and would spam the log once a
    /// day forever, so that one is silent. Anything else (offline, 404 feed, bad signature, …) is
    /// the only trace an unattended check leaves, so it's worth a line.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error = error as NSError? else { return }
        if error.domain == "SUSparkleErrorDomain" && error.code == 1001 { return }
        AppLogger.shared.warning("Update check failed: \(error.localizedDescription)")
    }
}
