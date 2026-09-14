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

    // MARK: - On means the stem is playing
    //
    // The switch is 34×18 with a 14pt knob inset 2pt. Playing (on) puts the knob right, at x 18…32, so
    // x = 6 is bare track; muted (off) puts it left, at x 2…16, so x = 28 is bare track. Sampled as a
    // fraction of the bitmap's width so the point holds at any backing scale.

    private func trackPixel(muted: Bool, appearance: NSAppearance.Name = .aqua) throws -> NSColor {
        let toggle = MuteToggleView(label: "Vocals")
        toggle.appearance = NSAppearance(named: appearance)
        toggle.setMuted(muted)
        let rep = try XCTUnwrap(toggle.bitmapImageRepForCachingDisplay(in: toggle.bounds))
        toggle.cacheDisplay(in: toggle.bounds, to: rep)
        let fraction: CGFloat = muted ? 28.0 / 34.0 : 6.0 / 34.0
        let x = Int(fraction * CGFloat(rep.pixelsWide))
        let color = try XCTUnwrap(rep.colorAt(x: x, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    /// Like every other switch in the app, coral means on — and on means sound. Sampling x = 6 also
    /// pins the knob to the right: were it still on the left for a playing stem, that point would be
    /// white knob, not coral track.
    func testAPlayingStemIsASolidCoralTrackWithTheKnobRight() throws {
        let pixel = try trackPixel(muted: false)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.95, "the playing track is not solid")
        XCTAssertGreaterThan(pixel.redComponent, 0.8)
        XCTAssertLessThan(pixel.greenComponent, 0.4, "a playing stem is not coral")
    }

    /// Muted is off: a neutral grey track with the knob on the left — no coral anywhere near it.
    func testAMutedStemIsANeutralGreyTrackWithTheKnobLeft() throws {
        let pixel = try trackPixel(muted: true)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.05, "the muted track draws nothing")
        // The grey is a translucent wash; the white knob is opaque. Without this a knob still sitting on
        // the right at x = 28 — white, so r = g = b — would pass the grey checks below.
        XCTAssertLessThan(pixel.alphaComponent, 0.9, "sampled an opaque fill: the knob isn't on the left, or the track is solid")
        XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.05, "the muted track is tinted, not grey")
        XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.05, "the muted track is tinted, not grey")
    }

    /// The grey is a light/dark-dependent colour, so the two appearances must actually paint differently.
    func testTheMutedTrackFollowsTheAppearance() throws {
        let light = try trackPixel(muted: true, appearance: .aqua)
        let dark = try trackPixel(muted: true, appearance: .darkAqua)
        XCTAssertGreaterThan(abs(light.brightnessComponent - dark.brightnessComponent), 0.3,
                             "the muted track paints the same grey in light and dark")
    }

    /// VoiceOver agrees with the picture: "Vocals, checked" while the stem plays, unchecked once muted.
    func testVoiceOverHearsCheckedWhileTheStemPlays() {
        let toggle = MuteToggleView(label: "Vocals")
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertEqual(toggle.accessibilityLabel(), "Vocals", "a label saying 'Mute' contradicts 'checked' meaning playing")
        XCTAssertEqual(toggle.accessibilityValue() as? Bool, true, "a playing stem doesn't read as checked")

        toggle.simulateClickForTesting()
        XCTAssertEqual(toggle.accessibilityValue() as? Bool, false, "muting by click didn't reach VoiceOver")

        // Isolating this stem unmutes it from outside, through setMuted.
        toggle.setMuted(false)
        XCTAssertEqual(toggle.accessibilityValue() as? Bool, true, "an external unmute didn't reach VoiceOver")
    }

    /// With the label now just the stem's name, the tooltip has to carry what a click does.
    func testTheTooltipSaysWhatAClickAndACommandClickDo() {
        let tooltip = MuteToggleView(label: "Vocals").toolTip ?? ""
        XCTAssertTrue(tooltip.contains("Vocals"), tooltip)
        XCTAssertTrue(tooltip.localizedCaseInsensitiveContains("click to mute"), tooltip)
        XCTAssertTrue(tooltip.contains("⌘-click"), tooltip)
    }
}
