import XCTest
@testable import MinusOne

final class StemMixerControllerTests: XCTestCase {
    func testANewStemPlaysAtFullFaderByDefault() {
        let mixer = StemMixerController()
        XCTAssertEqual(mixer.effectiveVolume(for: .vocals), 1, accuracy: 0.001)
    }

    func testMutingSilencesEffectiveVolumeRegardlessOfFader() {
        let mixer = StemMixerController()
        mixer.setVolume(0.8, for: .drums)
        mixer.setMuted(true, for: .drums)
        XCTAssertEqual(mixer.effectiveVolume(for: .drums), 0, accuracy: 0.001)
    }

    func testUnmutingRestoresTheFaderVolume() {
        let mixer = StemMixerController()
        mixer.setVolume(0.6, for: .bass)
        mixer.setMuted(true, for: .bass)
        mixer.setMuted(false, for: .bass)
        XCTAssertEqual(mixer.effectiveVolume(for: .bass), 0.6, accuracy: 0.001)
    }

    /// The Cmd-click gesture: mute every other stem, unmute this one — reached via one call
    /// instead of the old exclusive `soloedStem`.
    func testIsolateStemMutesEveryoneElseAndUnmutesTheTarget() {
        let mixer = StemMixerController()
        mixer.setMuted(true, for: .vocals)

        mixer.isolateStem(.drums)

        XCTAssertFalse(mixer.isMuted(.drums))
        XCTAssertTrue(mixer.isMuted(.vocals))
        XCTAssertTrue(mixer.isMuted(.bass))
        XCTAssertTrue(mixer.isMuted(.other))
    }

    /// Isolating a second stem must fully reassign the mute set, not just add to it — otherwise
    /// two isolates in a row would leave every stem muted.
    func testIsolatingADifferentStemReassignsWhichOneIsAudible() {
        let mixer = StemMixerController()
        mixer.isolateStem(.vocals)
        mixer.isolateStem(.other)

        XCTAssertFalse(mixer.isMuted(.other))
        XCTAssertTrue(mixer.isMuted(.vocals))
        XCTAssertTrue(mixer.isMuted(.drums))
        XCTAssertTrue(mixer.isMuted(.bass))
    }

    func testIsolatingAnAlreadyMutedSetOfStemsStillLeavesOnlyTheTargetAudible() {
        let mixer = StemMixerController()
        mixer.setMuted(true, for: .drums)
        mixer.setMuted(true, for: .bass)
        mixer.setMuted(true, for: .other)

        mixer.isolateStem(.vocals)

        for stem in SeparationStem.allCases {
            XCTAssertEqual(mixer.isMuted(stem), stem != .vocals, "\(stem) mute state after isolating vocals")
        }
    }
}
