import AppKit

/// Hosts Practice's Import/Record action row above the sidebar+deck split view.
///
/// The previous shape built this as a bare `NSView` holding `practiceSplitViewController.view`
/// as a plain subview, with the split view controller never added via `addChild(_:)` anywhere in
/// the app. `NSSplitViewController` computes its divider/holding-priority layout expecting the
/// normal view-controller lifecycle (`viewWillAppear`/`viewDidAppear`) to fire; skipping
/// containment is what produced the "gap above the button row, content pinned to the bottom of
/// the window" bug — the split view's initial layout was baked in against a not-yet-final frame
/// with no later pass to correct it. Wrapping it in a real parent view controller fixes that.
final class PracticeTabViewController: NSViewController {
    let importActionButton = WindowUI.toolbarActionButton(title: "Import", symbolName: "square.and.arrow.down", symbolPointSize: 12, target: nil, action: nil)
    let recordActionButton = WindowUI.toolbarActionButton(title: "Record", symbolName: "record.circle", symbolPointSize: 12, target: nil, action: nil)

    private let splitViewController: PracticeSplitViewController

    init(splitViewController: PracticeSplitViewController) {
        self.splitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = AutoLayoutView()
        view = root

        // `toolbarActionButton`'s default sizing (14pt/.black title + FlatButton's own +28.8w/
        // +16h padding) is tuned for a single prominent CTA (e.g. onboarding's "Download Neural
        // Model"), not a compact action row — left as-is it dwarfs the sidebar/deck below it. The
        // matching 12pt symbol size is passed at construction, above.
        for button in [importActionButton, recordActionButton] {
            button.pointSize = 12
            // 32, not 26. `FlatButton` used to inherit `NSButton`'s alignment rect insets, so a
            // 26pt constraint painted a 33.5pt box — this row's proportions were tuned against
            // that. Now that the constraint produces the size it says, the number has to be the
            // one that was always being drawn, or the buttons come out 7.5pt shorter.
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            // Matches the title bar's Live/Practice pill sitting directly above this row — at the
            // same 26pt height the two read as one family instead of two button languages.
            button.cornerStyle = .capsule
        }

        let actionRow = Layout.horizontalStack([importActionButton, recordActionButton], spacing: WindowUI.Metrics.rowSpacing)
        // Only pinned by leading+top below, with no height/bottom of its own — nothing stops
        // Auto Layout from stretching it to soak up whatever height `splitView` doesn't claim
        // (confirmed via direct frame logging: actionRow measured 374pt tall, not ~26pt, exactly
        // filling the gap between the button row's real height and wherever splitView ended up).
        // A hard height, matching the buttons it holds, removes it as a possible slack-absorber.
        actionRow.heightAnchor.constraint(equalToConstant: 32).isActive = true

        addChild(splitViewController)
        let splitView = splitViewController.view

        let pad = WindowUI.Metrics.padding
        Layout.pin(actionRow, to: root, edges: [.leading, .top], insets: NSEdgeInsets(top: WindowUI.Metrics.rowSpacing, left: pad, bottom: 0, right: 0))
        Layout.pin(splitView, to: root, edges: [.leading, .trailing, .bottom])
        // 4, not the full 8pt row spacing: both panes below already carry their own top padding
        // (10pt to the sidebar's search field, 24pt to the deck's content), so a full token gap
        // here stacks on top of that and reads as a hole under the buttons. Measured, this puts the
        // buttons 14pt above the clip search field — the spacing the row had before `FlatButton`'s
        // alignment-rect fix stopped its 33.5pt paint from overlapping the gap.
        splitView.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 4).isActive = true
    }
}
