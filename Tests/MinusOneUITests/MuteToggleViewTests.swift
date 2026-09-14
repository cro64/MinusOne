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

    // MARK: - Telling the states apart
    //
    // The switch is 34×18 with a 14pt knob inset 2pt. Muted puts the knob at x 18…32, so x = 6 is bare
    // track; audible puts it at x 2…16, so x = 28 is bare track. Sampled as a fraction of the bitmap's
    // width so the point holds at any backing scale.

    private func trackPixel(muted: Bool, appearance: NSAppearance.Name = .aqua) throws -> NSColor {
        let toggle = MuteToggleView(label: "Mute Vocals")
        toggle.appearance = NSAppearance(named: appearance)
        toggle.setMuted(muted)
        let rep = try XCTUnwrap(toggle.bitmapImageRepForCachingDisplay(in: toggle.bounds))
        toggle.cacheDisplay(in: toggle.bounds, to: rep)
        let fraction: CGFloat = muted ? 6.0 / 34.0 : 28.0 / 34.0
        let x = Int(fraction * CGFloat(rep.pixelsWide))
        let color = try XCTUnwrap(rep.colorAt(x: x, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    /// The bug: both states drew the same faint coral track, so only the knob's side told them apart.
    /// Muted is the "on" state and reads as the app's engaged colour — solid, not a tint.
    func testAMutedTrackIsSolidCoral() throws {
        let pixel = try trackPixel(muted: true)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.95, "the muted track is still a faint tint")
        XCTAssertGreaterThan(pixel.redComponent, 0.8)
        XCTAssertLessThan(pixel.greenComponent, 0.4)
    }

    /// Audible is the "off" state: a neutral grey track, like `ToggleSwitchView` off — no coral hue.
    func testAnAudibleTrackIsNeutralGreyNotCoral() throws {
        let pixel = try trackPixel(muted: false)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.05, "the audible track draws nothing")
        XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.05, "the audible track is tinted, not grey")
        XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.05, "the audible track is tinted, not grey")
    }

    /// The grey is a light/dark-dependent colour, so the two appearances must actually paint differently.
    func testTheAudibleTrackFollowsTheAppearance() throws {
        let light = try trackPixel(muted: false, appearance: .aqua)
        let dark = try trackPixel(muted: false, appearance: .darkAqua)
        XCTAssertGreaterThan(abs(light.brightnessComponent - dark.brightnessComponent), 0.3,
                             "the audible track paints the same grey in light and dark")
    }

    /// VoiceOver had the same problem as sight: a plain button with no value reads identically muted
    /// or not.
    func testVoiceOverHearsTheMutedState() {
        let toggle = MuteToggleView(label: "Mute Vocals")
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertEqual(toggle.accessibilityValue() as? Bool, false)

        toggle.simulateClickForTesting()
        XCTAssertEqual(toggle.accessibilityValue() as? Bool, true, "a click didn't reach the accessibility value")

        // Isolating another stem mutes this one from outside, through setMuted.
        toggle.setMuted(false)
        XCTAssertEqual(toggle.accessibilityValue() as? Bool, false, "an external state change didn't reach VoiceOver")
    }
}
