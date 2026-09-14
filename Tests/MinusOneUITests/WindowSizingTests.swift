import AppKit
import XCTest
@testable import MinusOne

final class WindowSizingTests: XCTestCase {
    func testTheDefaultAndTheFloorAreNoLongerTheSameValue() {
        XCTAssertNotEqual(WindowSizing.defaultContent, WindowSizing.minimum)
        XCTAssertGreaterThan(WindowSizing.defaultContent.width, WindowSizing.minimum.width)
        XCTAssertGreaterThan(WindowSizing.defaultContent.height, WindowSizing.minimum.height)
    }

    func testTheDefaultMatchesTheSpec() {
        XCTAssertEqual(WindowSizing.defaultContent, NSSize(width: 1120, height: 760))
        XCTAssertEqual(WindowSizing.minimum, NSSize(width: 900, height: 600))
    }

    /// Spec §8's arithmetic, as an assertion rather than a table: at the default width and the
    /// widest sidebar the deck still has a usable canvas.
    func testTheLaneCanvasIsWideEnoughAtTheDefaultSize() {
        let widestSidebar: CGFloat = 360
        let deckPadding = WindowUI.Metrics.padding * 2
        let canvas = WindowSizing.defaultContent.width - widestSidebar - deckPadding - TimelineMetrics.headerWidth
        XCTAssertGreaterThan(TimelineMetrics.barCount(forWidth: canvas), 150, "fewer than 150 bars fit the lane")
    }

    /// And at the floor it still fits vertically — the constraint that decides whether 900×600 is
    /// a floor or a promise the layout cannot keep.
    ///
    /// This **measures** the real deck rather than asserting a chrome literal. The first version of
    /// this test summed `52 + 66 + 90 + 24` by hand, and spec §8 itself annotated the 52pt header
    /// strip as "estimated — measure before fixing the numbers below". A hand-summed budget passes
    /// happily while the real window clips, which defeats the only test that exists to catch that.
    /// Measured: the deck's content stack wants 448pt against the 498pt those literals implied, so
    /// the original arithmetic was conservative — but only by luck.
    ///
    /// The Live/Practice header strip is the one figure still estimated: measuring it would mean
    /// constructing a real `MainWindowController`, which builds an `NSWindow` and an `AudioEngine`.
    /// It is isolated below, and the remaining slack absorbs a large error in it.
    func testTheDeckFitsTheMinimumWindowHeight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = PracticeDeckViewController(
            libraryStore: ClipLibraryStore(rootURL: root),
            playbackEngine: PracticePlaybackEngine()
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        // The deck view's own `fittingSize.height` is 0 — its content stack is pinned
        // top/leading/trailing with no bottom edge, so the view has no vertical intrinsic size.
        // The stack itself is the thing with a height.
        var stacks: [NSStackView] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView, stack.orientation == .vertical { stacks.append(stack) }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        let deckContent = try XCTUnwrap(stacks.map(\.fittingSize.height).max())
        XCTAssertGreaterThan(
            deckContent, DeckTimelineView.height(forLaneCount: 4),
            "the measured stack does not even contain the timeline — the wrong stack was found"
        )

        // Was 52 when the Practice tab also carried an Import/Record strip above the split
        // view; that row was deleted, so the deck now sits directly under the title bar row.
        let headerStrip = MainWindowController.headerHeight
        let needed = deckContent + WindowUI.Metrics.padding + headerStrip
        // Printed because `TimelineMetrics.laneHeight`'s docstring quotes this figure as the reason
        // the compress-then-scroll path in spec §8 is unreachable. A quoted number nobody can
        // re-derive goes stale silently — the previous one did.
        print("MEASURED deck height: stack \(deckContent) + padding \(WindowUI.Metrics.padding) "
              + "+ header \(headerStrip) = \(needed)pt against a \(WindowSizing.minimum.height)pt floor")
        XCTAssertLessThanOrEqual(
            needed, WindowSizing.minimum.height,
            "the deck needs \(needed)pt but the floor is \(WindowSizing.minimum.height)pt"
        )
    }

    /// The hero waveform adds height to the same vertical stack `testTheDeckFitsTheMinimumWindowHeight`
    /// measures. This re-runs that measurement with the hero pinned to its resize-handle maximum —
    /// the worst case a user can actually reach — rather than only its 64pt default, since the
    /// default alone would not catch a max clamp that was set too generously.
    func testTheDeckStillFitsTheMinimumWindowHeightWithTheHeroAtItsMaximum() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = PracticeDeckViewController(
            libraryStore: ClipLibraryStore(rootURL: root),
            playbackEngine: PracticePlaybackEngine()
        )
        controller.loadView()
        controller.heroHeightConstraintForTesting.isActive = false
        controller.heroWaveformViewForTesting.heightAnchor.constraint(
            equalToConstant: HeroWaveformView.maximumHeight
        ).isActive = true
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        var stacks: [NSStackView] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView, stack.orientation == .vertical { stacks.append(stack) }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        let deckContent = try XCTUnwrap(stacks.map(\.fittingSize.height).max())

        // Was 52 when the Practice tab also carried an Import/Record strip above the split
        // view; that row was deleted, so the deck now sits directly under the title bar row.
        let headerStrip = MainWindowController.headerHeight
        let needed = deckContent + WindowUI.Metrics.padding + headerStrip
        print("MEASURED deck height with hero at max: stack \(deckContent) + padding \(WindowUI.Metrics.padding) "
              + "+ header \(headerStrip) = \(needed)pt against a \(WindowSizing.minimum.height)pt floor")
        XCTAssertLessThanOrEqual(
            needed, WindowSizing.minimum.height,
            "the deck needs \(needed)pt but the floor is \(WindowSizing.minimum.height)pt"
        )
    }

    /// Companion to `testTheDeckStillFitsTheMinimumWindowHeightWithTheHeroAtItsMaximum`: that test
    /// (and `testTheDeckFitsTheMinimumWindowHeight` before it) measures with `statusLabel` at its
    /// construction-time `isHidden = true` — but `refreshForCurrentClip()` makes it visible with
    /// real text ("Separating in the background…") for as long as a clip is still separating, which
    /// is a common state, not an edge case. This re-measures the hero-at-maximum case with the
    /// status label visible, the way the app actually shows it.
    func testTheDeckStillFitsTheMinimumWindowHeightWithTheHeroAtItsMaximumAndStatusVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = PracticeDeckViewController(
            libraryStore: ClipLibraryStore(rootURL: root),
            playbackEngine: PracticePlaybackEngine()
        )
        controller.loadView()
        controller.heroHeightConstraintForTesting.isActive = false
        controller.heroWaveformViewForTesting.heightAnchor.constraint(
            equalToConstant: HeroWaveformView.maximumHeight
        ).isActive = true
        controller.statusLabelForTesting.stringValue = "Separating in the background… 1:00 ready of 4:00"
        controller.statusLabelForTesting.isHidden = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        var stacks: [NSStackView] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView, stack.orientation == .vertical { stacks.append(stack) }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        let deckContent = try XCTUnwrap(stacks.map(\.fittingSize.height).max())

        // Was 52 when the Practice tab also carried an Import/Record strip above the split
        // view; that row was deleted, so the deck now sits directly under the title bar row.
        let headerStrip = MainWindowController.headerHeight
        let needed = deckContent + WindowUI.Metrics.padding + headerStrip
        print("MEASURED deck height with hero at max, status visible: stack \(deckContent) + padding "
              + "\(WindowUI.Metrics.padding) + header \(headerStrip) = \(needed)pt against a "
              + "\(WindowSizing.minimum.height)pt floor")
        XCTAssertLessThanOrEqual(
            needed, WindowSizing.minimum.height,
            "the deck needs \(needed)pt but the floor is \(WindowSizing.minimum.height)pt"
        )
    }

    /// Same companion, but at the hero's *default* height rather than its resize-handle maximum —
    /// the reviewer's estimate suggested even the default might be razor-thin once `statusLabel` is
    /// accounted for, so this measures that combination directly rather than assuming the default
    /// is automatically safe because it is smaller than the maximum.
    func testTheDeckFitsTheMinimumWindowHeightAtDefaultHeroHeightWithStatusVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = PracticeDeckViewController(
            libraryStore: ClipLibraryStore(rootURL: root),
            playbackEngine: PracticePlaybackEngine()
        )
        controller.loadView()
        controller.statusLabelForTesting.stringValue = "Separating in the background… 1:00 ready of 4:00"
        controller.statusLabelForTesting.isHidden = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        var stacks: [NSStackView] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView, stack.orientation == .vertical { stacks.append(stack) }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        let deckContent = try XCTUnwrap(stacks.map(\.fittingSize.height).max())

        // Was 52 when the Practice tab also carried an Import/Record strip above the split
        // view; that row was deleted, so the deck now sits directly under the title bar row.
        let headerStrip = MainWindowController.headerHeight
        let needed = deckContent + WindowUI.Metrics.padding + headerStrip
        print("MEASURED deck height at default hero height, status visible: stack \(deckContent) + padding "
              + "\(WindowUI.Metrics.padding) + header \(headerStrip) = \(needed)pt against a "
              + "\(WindowSizing.minimum.height)pt floor")
        XCTAssertLessThanOrEqual(
            needed, WindowSizing.minimum.height,
            "the deck needs \(needed)pt but the floor is \(WindowSizing.minimum.height)pt"
        )
    }

    /// Width companion to `testTheDeckFitsTheMinimumWindowHeight`: at `WindowSizing.minimum` the
    /// sidebar claims its `minimumThickness` (`PracticeSplitViewController.swift:15`) and the deck
    /// pane is padded on both sides, so whatever is left over is the control bar's real budget.
    ///
    /// Measured, not derived, the same way the height test insists on — a hand-summed cluster
    /// width silently goes stale exactly like a hand-summed chrome literal would.
    func testTheControlBarFitsTheMinimumWindowWidth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = PracticeDeckViewController(
            libraryStore: ClipLibraryStore(rootURL: root),
            playbackEngine: PracticePlaybackEngine()
        )
        controller.loadView()

        // The same 220pt `minimumThickness` PracticeSplitViewController.swift:15 gives the sidebar
        // item — not exposed as a shared constant, so mirrored here as the height test mirrors its
        // own 52pt header strip.
        let sidebarMinimumThickness: CGFloat = 220
        let deckPadding = WindowUI.Metrics.padding * 2
        let availableContentWidth = WindowSizing.minimum.width - sidebarMinimumThickness - deckPadding
        controller.view.frame = NSRect(x: 0, y: 0, width: availableContentWidth + deckPadding, height: 900)
        controller.view.layoutSubtreeIfNeeded()

        var stacks: [NSStackView] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView, stack.orientation == .horizontal { stacks.append(stack) }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        // The control bar is the horizontal stack that directly arranges the BPM/Tap toolbar —
        // `controlBar` itself is private, so this is the least invasive way to find it from a test.
        let toolbar = controller.toolbarForTesting
        let controlBar = try XCTUnwrap(
            stacks.first { $0.arrangedSubviews.contains(toolbar) },
            "couldn't find the control bar — expected a horizontal stack directly containing the toolbar"
        )

        let fittingWidth = controlBar.fittingSize.width
        // Printed for the same reason the height test prints its figure: a quoted number nobody can
        // re-derive goes stale silently.
        print("MEASURED control bar width: \(fittingWidth)pt against \(availableContentWidth)pt available "
              + "(minimum window \(WindowSizing.minimum.width)pt - sidebar \(sidebarMinimumThickness)pt "
              + "- padding \(deckPadding)pt)")
        XCTAssertLessThanOrEqual(
            fittingWidth, availableContentWidth,
            "the control bar needs \(fittingWidth)pt but only \(availableContentWidth)pt is available"
        )
    }
}
