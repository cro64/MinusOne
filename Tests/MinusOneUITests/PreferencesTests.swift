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

    func testLiveStemFaderDefaultsToFullVolumeForEveryStem() {
        let preferences = freshPreferences()
        for stem in SeparationStem.allCases {
            XCTAssertEqual(preferences.liveStemFaderVolume(for: stem), 1, accuracy: 0.001)
        }
    }

    func testMutedLiveStemsDefaultsToVocalsOnly() {
        XCTAssertEqual(freshPreferences().mutedLiveStems, [.vocals])
    }

    func testLiveStemFaderVolumeRoundTrips() {
        let preferences = freshPreferences()
        preferences.setLiveStemFaderVolume(0.4, for: .drums)
        XCTAssertEqual(preferences.liveStemFaderVolume(for: .drums), 0.4, accuracy: 0.001)
    }

    func testLiveStemFaderVolumeClampsToUnitRange() {
        let preferences = freshPreferences()
        preferences.setLiveStemFaderVolume(5, for: .bass)
        XCTAssertEqual(preferences.liveStemFaderVolume(for: .bass), 1, accuracy: 0.001)

        preferences.setLiveStemFaderVolume(-5, for: .bass)
        XCTAssertEqual(preferences.liveStemFaderVolume(for: .bass), 0, accuracy: 0.001)
    }

    func testMutedLiveStemsRoundTrips() {
        let preferences = freshPreferences()
        preferences.mutedLiveStems = [.vocals, .bass]
        XCTAssertEqual(preferences.mutedLiveStems, [.vocals, .bass])
    }

    /// The stem-mixer snapshot is what `AudioEngine` actually pushes into the live pipeline — this
    /// pins that a fresh install reproduces the old single-slider "remove vocals" default exactly.
    func testLiveStemMixerSnapshotReproducesTodaysDefaultBehavior() {
        let mixer = freshPreferences().liveStemMixerSnapshot()
        XCTAssertEqual(mixer.effectiveVolume(for: .vocals), 0, accuracy: 0.001)
        XCTAssertEqual(mixer.effectiveVolume(for: .drums), 1, accuracy: 0.001)
        XCTAssertEqual(mixer.effectiveVolume(for: .bass), 1, accuracy: 0.001)
        XCTAssertEqual(mixer.effectiveVolume(for: .other), 1, accuracy: 0.001)
    }

    func testPersistLiveStemMixerRoundTripsThroughSnapshot() {
        let preferences = freshPreferences()
        let mixer = StemMixerController()
        mixer.setVolume(0.25, for: .other)
        mixer.isolateStem(.drums)

        preferences.persistLiveStemMixer(mixer)
        let reloaded = preferences.liveStemMixerSnapshot()

        XCTAssertEqual(reloaded.effectiveVolume(for: .drums), 1, accuracy: 0.001)
        XCTAssertEqual(reloaded.effectiveVolume(for: .vocals), 0, accuracy: 0.001)
        XCTAssertEqual(reloaded.effectiveVolume(for: .bass), 0, accuracy: 0.001)
        XCTAssertEqual(reloaded.effectiveVolume(for: .other), 0, accuracy: 0.001)
        XCTAssertEqual(reloaded.volume(for: .other), 0.25, accuracy: 0.001)
    }
}
