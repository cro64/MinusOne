import AppKit

/// `NSView` whose `translatesAutoresizingMaskIntoConstraints` defaults to `false` — the correct
/// default for every view in this codebase, which is laid out entirely with constraints. AppKit's
/// own default of `true` is what produced the Practice sidebar/deck/action-row layout bugs: a
/// programmatically created view resolves its frame via its (unset, `.zero`) autoresizing mask
/// against whatever frame it happened to be created with, instead of the constraints meant to
/// size it — visible only once the view is embedded somewhere (e.g. an `NSSplitViewItem`) that
/// doesn't itself force the flag off. Subclass this instead of `NSView` for any programmatic root
/// or container view and the failure mode stops being possible.
class AutoLayoutView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }
}

extension NSView {
    /// Activates width/height constraints pinning this view to a fixed size — covers the ~13
    /// duplicated `widthAnchor.constraint(equalToConstant:)` + `heightAnchor...` pairs scattered
    /// across the app for small fixed-size views (status dots, icons, square buttons).
    @discardableResult
    func constrainSize(width: CGFloat, height: CGFloat) -> (width: NSLayoutConstraint, height: NSLayoutConstraint) {
        translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = widthAnchor.constraint(equalToConstant: width)
        let heightConstraint = heightAnchor.constraint(equalToConstant: height)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        return (widthConstraint, heightConstraint)
    }
}

/// Generic Auto Layout composition helpers — no design-system opinion, used identically by the
/// menu bar popover (`PopoverUI`) and the desktop window (`WindowUI`). Used to live under
/// `PopoverUI`'s name, which made it look like popover-only infrastructure when it never was.
enum Layout {
    /// Which edges `pin(_:to:edges:insets:)` constrains to the container's matching edge.
    struct PinnedEdges: OptionSet {
        let rawValue: Int
        static let leading = PinnedEdges(rawValue: 1 << 0)
        static let trailing = PinnedEdges(rawValue: 1 << 1)
        static let top = PinnedEdges(rawValue: 1 << 2)
        static let bottom = PinnedEdges(rawValue: 1 << 3)
        static let all: PinnedEdges = [.leading, .trailing, .top, .bottom]
    }

    /// Adds `view` to `container` (if not already a subview of it) and activates constraints
    /// pinning `edges` to the matching edges of `container`, inset by `insets`. Covers the ~20
    /// hand-written "pin this view to its container" constraint blocks that used to be scattered
    /// across the app, each rewritten slightly differently — a single call site here is one fewer
    /// place to get an edge or a sign wrong.
    @discardableResult
    static func pin(_ view: NSView, to container: NSView, edges: PinnedEdges = .all, insets: NSEdgeInsets = NSEdgeInsetsZero) -> [NSLayoutConstraint] {
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.superview !== container {
            container.addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = []
        if edges.contains(.leading) {
            constraints.append(view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left))
        }
        if edges.contains(.trailing) {
            constraints.append(view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right))
        }
        if edges.contains(.top) {
            constraints.append(view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top))
        }
        if edges.contains(.bottom) {
            constraints.append(view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom))
        }
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func horizontalStack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Content-less view with minimal horizontal hugging priority — the lowest-priority view in a
    /// horizontal stack absorbs all the stack's slack, pushing its neighbors to opposite ends
    /// without a fixed-width spacer.
    static func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
}
