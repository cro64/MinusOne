# MinusOne Redesign — Handoff

**Branch:** `worktree-agent-a05326ccdb9690779` (in this worktree, based off `practice-mode` at `30bedd8`)
**Latest commit:** `c52f29c`
**Status:** Not merged into `practice-mode`. Working tree is clean — everything below is committed.

This implements `REDESIGN.md` (Live/Practice reconsolidation) plus several rounds of visual
fixes after live review. It is **not fully working** — see "Known broken" below before doing
anything else with it.

## How to build and run

```bash
cd /Users/chenlinghuang/Projects/MinusOne/.claude/worktrees/agent-a05326ccdb9690779
./Scripts/build-app.sh debug        # builds build/MinusOne.app
open build/MinusOne.app
```

The app is a menu-bar app (`.accessory` activation policy with no window open). Click its menu
bar icon → "Open MinusOne…" to see the window.

## How to test

A real XCUITest target exists (SPM's own `.testTarget` can't produce a UI-Testing-Bundle product
type, so this uses `xcodegen` to generate a throwaway `.xcodeproj` — the generated project is
gitignored, `project.yml` is the source of truth):

```bash
xcodegen generate
./Scripts/build-app.sh debug
xcodebuild test -project MinusOneUITests.xcodeproj -scheme MinusOneUITests -destination 'platform=macOS,arch=arm64'
```

Two tests exist in `Tests/MinusOneUITests/MinusOneUITests.swift`, both passing as of `c52f29c`:
- `testLiveTabTitleBarSwitchExists` — title-bar Live/Practice control renders with nonzero size.
- `testCaptureChecklistOnlyShowsForCustomScope` — Capture app-checklist visibility + no overlap.

**Environment gotcha:** this machine's external display is arranged higher than the built-in
display, which occasionally makes the menu bar status item report a bogus off-screen (negative-y)
duplicate accessibility element. `openMainWindow()` in the test file already filters for a
plausible on-screen element to work around this — if a test fails specifically at the
menu-bar-click step with a "not hittable" error, rerun it before assuming it's a real bug.

**Permissions needed once per machine** for the test runner to work at all:
- System Settings → Privacy & Security → **Accessibility** → enable your terminal
- System Settings → Privacy & Security → **Developer Tools** → enable your terminal (needed for
  `xcodebuild` to sign the entitled UI-testing bundle — without it you'll see a cryptic
  `ld: open() failed, errno=1 (Operation not permitted)` linker error that looks unrelated)

## What's built (commit-by-commit, oldest first)

1. `54d062e` — Core redesign shell: `MainWindowController` (Live/Practice window, `.accessory`/
   `.regular` activation-policy switching), `brandAccent` design-system color, Center Cut/Direct
   mode fully removed, minimal menu bar popover, Practice tab restyle, onboarding/model gating.
2. `0b9e8e5`–`c5594f6` — RecordingTheme folded into the brand system, recording icon changed from
   a badge to a separate glyph, Capture scope picker replaced with a real multi-select checklist.
3. `f651237`–`3408f10` — Fixed the Live tab rendering as a tiny invisible popover box (it was
   reusing floating-popover chrome inside a regular window), plus titlebar/opacity/slider/overlap
   follow-up fixes. **Two of these fixes did not actually work** and needed a second pass — see
   `1096bdb`.
4. `1096bdb` — Real fixes for the titlebar switch and checklist bugs (traced via a captured
   accessibility hierarchy dump, not guessed), plus the XCUITest infrastructure itself.
5. `2a0503c` — First visual pass: flat/square "Modernist" design system tokens (zero corner
   radius, custom flat buttons, 4/8/12/16/24/32 spacing scale, heavier headings) applied
   everywhere, replacing native macOS chrome.
6. `46e0d4e` — **Reversed most of #5 for the menu bar popover specifically**, per user direction:
   the popover reverts to native macOS chrome (rounded corners, native hairlines, native link
   buttons); the desktop window keeps the flat/square look. This "mixed by surface" split is the
   current intended design direction — don't re-flatten the popover.
7. `0dae0c5` — Fixed the popover's toggle/footer rows not stretching to the panel's width
   (visible gutter on the right).
8. `67c508d` — Centered Live tab content horizontally instead of pinning it to the left edge.
9. `9e40e23` — Title-bar Live/Practice switch restyled as a sliding pill/capsule toggle instead
   of flat rectangular segments.
10. `6c28c69` — Moved Practice's Import/Record buttons out of the native title-bar `NSToolbar`
    into the Practice tab's own content (a row above the sidebar+deck split) — the bold flat
    button style read as oversized/out of place in a native toolbar.
11. `c52f29c` — Capped Import/Record's size (icon/font/height), since #10 initially made them
    dwarf the sidebar.

## Known broken — start here

**After `c52f29c`, the Practice tab's layout is visibly broken.** User-reported and confirmed via
screenshot: there's a large unexplained empty gap between the title bar and the Import/Record
button row, and the sidebar/deck content (search field, "No clip selected" empty state) renders
pushed down near the very bottom of the window instead of filling the space below the button row.

Investigation so far (in `MainWindowController.swift`'s `practiceContainer` lazy property,
~line 270): the Auto Layout constraints connecting `actionRow` → `splitView` → `container` look
structurally correct on paper (verified by re-reading twice), and `ClipSidebarViewController`'s
own internal layout (its search field is properly top-anchored) is *not* the bug either. The
actual root cause was not found before this session ended — likely something about how
`practiceSplitViewController.view` behaves when embedded this way (possibly related to it never
being added via `addChild(_:)` to a real view-controller parent, since `MainWindowController` is
an `NSWindowController` not an `NSViewController` — though the same pattern works fine for
`LiveTabViewController`). **Next step: use the XCUITest suite to dump exact frame coordinates for
`actionRow`, the split view, and the search field** (the same technique that found the real cause
of the titlebar-switch bug in `1096bdb` — see that commit message) rather than guessing again from
screenshots alone.

## Other open items

- REDESIGN.md §7's `RecordingTheme.swift` question is resolved (folded into brand system, `0b9e8e5`).
- Not yet done: verify the Practice tab's stem-color/empty-state polish still looks right after
  all the surrounding layout churn — untested since before the design-system passes.
- This branch has never been merged into `practice-mode`. Do that only after the Practice tab
  layout bug above is actually fixed and re-verified.
