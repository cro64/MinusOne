# Live tab — design directions for the desktop window

Companion to `REDESIGN.md` (which specced the Live/Practice reconsolidation and got the tab
onto a real window) and consistent with the brand system already shipped in `WindowUI.swift` /
`DesignColors.swift` (flat/branded chrome, `brandAccent` coral, the 4/8/12/16/24/32 spacing
scale) and the recording-indicator icon-state work in `MenuBarController`/`MinusOneIcon`.

## What exists today

`LiveTabViewController` renders a single vertical stack — Status row, Processing section
(Intensity + Gain sliders), Capture section (Scope popup + a 4.5-row-tall app checklist) —
centered horizontally in a **980×640 window** (`MainWindowController`'s `defaultContentSize`,
also the enforced `minSize`, i.e. the window can grow but nothing reflows if it does). The stack
is pinned to a fixed **420pt width** and top-anchored with padding, not vertically centered or
stretched.

Concretely: that content measures roughly 300pt tall. In an ~610pt-tall content area, more than
half the window is empty below the controls, and roughly 560pt of horizontal width is dead space
either side of the column. The `AppCaptureChecklistView` is still capped at 4.5 visible rows —
a limit that made sense when it had to fit inside a ~190pt popover, not inside a resizable
window with hundreds of spare vertical points. This is the literal shape of "copy-pasted from
the menu bar dropdown": the information architecture and control sizing never moved past
popover constraints, only the window chrome around them changed.

The design system to build on already exists and is solid — flat sections via
`WindowUI.section(...)`, `FlatButton`, `brandAccent`/`brandAccentDeep` status-color semantics
that already match the menu bar icon and popover 1:1 (On = accent, Warming up = cyan, Permission
needed = orange, Error = red). Any direction below should extend those tokens, not invent new
ones.

## Direction A — Honest minimal-content layout (low risk)

Stop pretending there's more content than there is. Keep the single-column form, but stop
top-pinning it in a giant window: center it both horizontally *and* vertically, scale up type and
control sizing modestly (bigger status dot/text, taller slider hit targets — REDESIGN.md already
flags this as the "settle in and configure" surface, not the glance-and-go one), and let the
window's `minSize` shrink to something closer to the content's natural size instead of forcing
980×640 as a floor for a 300pt-tall form.

**Tradeoffs:** cheapest to build, lowest regression risk, and arguably the most honest given
Live's actual content is one toggle and two sliders. But it doesn't really solve the brief —
it's still a popover's worth of content, just breathing more. If Live ever gains more (a level
meter, session stats, per-app overrides) this layout has nowhere to grow without a rework.

## Direction B — Status hero + control rail (moderate risk)

Split into two columns. Left: a large hero panel — big On/Off state (dot + label at 2–3x the
current size), a bigger primary toggle, and room for at-a-glance context that doesn't exist
today (e.g. active capture scope, elapsed time since Live was turned on). Right: the existing
Processing and Capture sections as vertically stacked cards, each with real padding instead of
compressed form rows.

This uses the width the window actually has and gives Live a visual identity beyond "the
settings screen" — the hero status becomes the thing you glance at from across the room, the
same way the menu bar icon is the thing you glance at from the corner of your eye. Same
`brandAccentDeep`/cyan/orange/red mapping, just rendered at a scale a menu bar never could
afford.

**Tradeoffs:** meaningfully more layout work than A (two-column Auto Layout, responsive behavior
at the 980pt minimum vs. wider). Still achievable with content that already exists — no new data
sources required. Risk is under-filling the left column if "bigger status text" is all it holds;
worth pairing with at least one more data point (elapsed-on time, or capture scope summary) so
the hero doesn't read as empty space with a big font.

## Direction C — Live meter as the hero (higher risk, most "native app" payoff)

Same two-column shell as B, but the left column's hero is a real-time visualization — a
continuous level/reduction meter reusing the drawing approach already in `LiveWaveformView`
(currently built for Practice's recording waveform, not live monitoring). Instead of a static
dot, you'd see vocal reduction actually happening while Live is on: input level, or a
before/after split showing what's being suppressed.

This is the direction that most justifies "why does this need a whole window" — a live meter is
inherently ambient, glanceable, and impossible to do justice in a menu bar dropdown. It's the
kind of content that turns Live from "a settings panel that happens to be full-screen" into
something that feels like dedicated software.

**Tradeoffs:** real engineering dependency that doesn't exist yet — confirm whether `AudioEngine`
currently exposes a continuous level stream during live monitoring (as opposed to
`SystemAudioRecorder`'s peak buckets, which are recording-session-scoped) before committing to
this. If it doesn't, this becomes an audio-engine task, not just a UI one. Highest payoff, highest
cost, and the one most likely to slip a layout-focused pass into a multi-week feature.

## Direction D — Card grid (System Settings-style) (moderate risk, lowest new-surface-area)

Keep everything single-column in spirit, but render Status/Processing/Capture as distinct
bordered/shadowed cards (the flat design system already has the visual language for this via
`WindowUI.separator()`/section styling) laid out in a loose grid that actually uses window width
— e.g. Processing and Capture side-by-side as two cards under a full-width Status card, each
with generous internal padding. This mirrors the pattern macOS's own System Settings uses for
panes like Sound or Displays, which is a legible "this is native to a desktop window" cue users
already know.

Capture's checklist stops being capped at 4.5 rows — its card can just be taller, since there's
finally room, which fixes a real usability complaint (REDESIGN.md §3 already called the old
picker "one of the more awkward interactions in the app").

**Tradeoffs:** no new data or audio-engine work needed — purely a reorganization + restyling of
content that already exists, so it's shippable fast. Less differentiated than C ("looks like a
nice settings pane" vs. "feels like dedicated software"), but low risk of the "big font, still
empty" problem Direction B risks if under-executed.

## Recommendation

Ship **D now, and treat C as the follow-up** once (or if) live level-metering is confirmed
feasible in `AudioEngine`.

D is the direction that most directly fixes what's actually broken today — fixed-width column
floating in unused window space, a checklist still artificially capped at popover-era row
limits, sections that don't use the design system's own card/section primitives to their full
extent — without inventing new product surface area or taking on an audio-engine dependency to
do it. It reuses every token already in `WindowUI`/`DesignColors` and keeps the exact status
color semantics already shared with the menu bar icon and popover, so Live's window state and
its menu-bar state keep reading as the same thing at two different scales, which was the whole
point of the icon-state consistency work.

Once D ships, re-evaluate C specifically: if `AudioEngine` can stream a live level signal cheaply,
promoting D's Status card into C's live meter is a natural next iteration rather than a rebuild —
the card grid shell doesn't need to change, only what's inside the top card.

A is worth keeping in back pocket only if D's timeline turns out too tight — it's strictly less
work but doesn't move the product forward the way D does for roughly the same design-system
groundwork. B is the one direction I'd skip outright: it takes on real layout risk (two-column
Auto Layout, a hero panel needing enough content to not look empty) without D's "fast + fixes a
real bug" advantage or C's "actually differentiated" payoff — it sits in an awkward middle.
