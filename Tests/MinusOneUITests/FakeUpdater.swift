@testable import MinusOne

/// Stands in for Sparkle, whose appcast items and update states can't be built outside a real
/// update session.
final class FakeUpdater: UpdaterDriving {
    var canCheckForUpdates = true
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}
