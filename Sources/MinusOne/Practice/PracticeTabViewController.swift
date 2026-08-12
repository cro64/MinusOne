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
    let importActionButton = PopoverUI.toolbarActionButton(title: "Import", symbolName: "square.and.arrow.down", target: nil, action: nil)
    let recordActionButton = PopoverUI.toolbarActionButton(title: "Record", symbolName: "record.circle", target: nil, action: nil)

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
        // +16h padding, plus an unconfigured SF Symbol rendering at its full default point size)
        // is tuned for a single prominent CTA (e.g. onboarding's "Download Neural Model"), not a
        // compact action row — left as-is it dwarfs the sidebar/deck below it.
        for button in [importActionButton, recordActionButton] {
            button.pointSize = 12
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }

        let actionRow = PopoverUI.horizontalStack([importActionButton, recordActionButton], spacing: PopoverUI.Metrics.Regular.rowSpacing)
        // Only pinned by leading+top below, with no height/bottom of its own — nothing stops
        // Auto Layout from stretching it to soak up whatever height `splitView` doesn't claim
        // (confirmed via direct frame logging: actionRow measured 374pt tall, not ~26pt, exactly
        // filling the gap between the button row's real height and wherever splitView ended up).
        // A hard height, matching the buttons it holds, removes it as a possible slack-absorber.
        actionRow.heightAnchor.constraint(equalToConstant: 26).isActive = true

        addChild(splitViewController)
        let splitView = splitViewController.view

        let pad = PopoverUI.Metrics.Regular.padding
        PopoverUI.pin(actionRow, to: root, edges: [.leading, .top], insets: NSEdgeInsets(top: PopoverUI.Metrics.Regular.rowSpacing, left: pad, bottom: 0, right: 0))
        PopoverUI.pin(splitView, to: root, edges: [.leading, .trailing, .bottom])
        splitView.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: PopoverUI.Metrics.Regular.rowSpacing).isActive = true
    }
}
