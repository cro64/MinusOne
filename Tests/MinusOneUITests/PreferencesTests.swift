import XCTest
@testable import MinusOne

final class PreferencesTests: XCTestCase {
    private func freshPreferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "PreferencesTests-\(UUID().uuidString)"))
    }

    func testHeroWaveformEnabledDefaultsToTrue() {
        XCTAssertTrue(freshPreferences().heroWaveformEnabled)
    }

    func testHeroWaveformEnabledRoundTrips() {
        let preferences = freshPreferences()
        preferences.heroWaveformEnabled = false
        XCTAssertFalse(preferences.heroWaveformEnabled)
    }

    func testHeroWaveformHeightDefaultsToFortyFive() {
        XCTAssertEqual(freshPreferences().heroWaveformHeight, 45, accuracy: 0.01)
    }

    func testHeroWaveformHeightRoundTrips() {
        let preferences = freshPreferences()
        preferences.heroWaveformHeight = 50
        XCTAssertEqual(preferences.heroWaveformHeight, 50, accuracy: 0.01)
    }

    func testHeroWaveformHeightClampsToTheHeroViewsRange() {
        let preferences = freshPreferences()
        preferences.heroWaveformHeight = 1000
        XCTAssertEqual(preferences.heroWaveformHeight, Double(HeroWaveformView.maximumHeight), accuracy: 0.01)

        preferences.heroWaveformHeight = -50
        XCTAssertEqual(preferences.heroWaveformHeight, Double(HeroWaveformView.minimumHeight), accuracy: 0.01)
    }
}
