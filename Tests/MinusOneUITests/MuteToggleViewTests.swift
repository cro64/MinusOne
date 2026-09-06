import AppKit
import XCTest
@testable import MinusOne

final class MuteToggleViewTests: XCTestCase {
    func testStartsUnmuted() {
        XCTAssertFalse(MuteToggleView(label: "Mute Vocals").isMuted)
    }

    /// A plain click flips local state immediately and reports the new value — same "self-driven"
    /// behavior the old mute button had, since muting is a single-lane action with no cross-lane
    /// side effect to wait for.
    func testClickTogglesLocalStateAndReportsBothDirections() {
        let toggle = MuteToggleView(label: "Mute Vocals")
        var reported: [Bool] = []
        toggle.onMuteToggled = { reported.append($0) }

        toggle.simulateClickForTesting()
        XCTAssertTrue(toggle.isMuted)
        toggle.simulateClickForTesting()
        XCTAssertFalse(toggle.isMuted)

        XCTAssertEqual(reported, [true, false])
    }

    /// Cmd-click is cross-lane (it mutes every other stem too), so this view can't predict the
    /// resulting state on its own — it only asks, and waits to be told back via `setMuted(_:)`.
    func testCmdClickRequestsIsolationWithoutPredictingLocalState() {
        let toggle = MuteToggleView(label: "Mute Vocals")
        var isolateCount = 0
        var muteReports: [Bool] = []
        toggle.onIsolateRequested = { isolateCount += 1 }
        toggle.onMuteToggled = { muteReports.append($0) }

        toggle.simulateCmdClickForTesting()

        XCTAssertEqual(isolateCount, 1)
        XCTAssertTrue(muteReports.isEmpty, "isolate must not also fire a plain mute toggle")
        XCTAssertFalse(toggle.isMuted, "isolate must not locally flip state before being told")
    }

    func testSetMutedUpdatesStateWithoutFiringCallbacks() {
        let toggle = MuteToggleView(label: "Mute Vocals")
        var reported: [Bool] = []
        toggle.onMuteToggled = { reported.append($0) }

        toggle.setMuted(true)

        XCTAssertTrue(toggle.isMuted)
        XCTAssertTrue(reported.isEmpty, "an externally-driven state update must not re-fire the toggle callback")
    }

    func testSetMutedToTheSameValueIsANoOp() {
        let toggle = MuteToggleView(label: "Mute Vocals")
        toggle.setMuted(true)
        toggle.needsDisplay = false
        toggle.setMuted(true)
        XCTAssertFalse(toggle.needsDisplay, "setting the same mute state again should not trigger a redraw")
    }
}
