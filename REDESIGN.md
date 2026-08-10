# MinusOne — Live/Practice Reconsolidation Spec (v1)

Status: proposal, not yet built. Companion to `README.md` (current shipped behavior) and `TASKS.md` (working task list). This document exists to be turned into implementation tasks once approved.

## 0. Decisions this spec is built on

- Most functionality moves into a single desktop app window. The menu bar becomes a thin remote control.
- The window has a Live / Practice switch, top-right.
- Live tab inherits everything currently in the menu bar settings popover.
- **Center Cut is removed.** MinusOne becomes Demucs-only.
- **Direct (passthrough-as-a-selectable-mode) is removed too.** There is no "Mode" picker anymore — Live is either off (passthrough) or on (Neural).
- Menu bar keeps: Live toggle, Record toggle, status.
- Record triggered from the menu bar needs its own visible feedback (not just a silent background action).
- Onboarding — including the now-mandatory Neural model download — moves into the desktop window.
- Accent color across the whole app becomes the logo's coral, `#E8475A` (`srgb 0.910, 0.278, 0.353`, from `Resources/MinusOne.icon/icon.json`), replacing `.controlAccentColor` everywhere.

---

## 1. App shell & window behavior

**Activation policy.** MinusOne stays a menu-bar-first app in spirit. The Dock icon is not permanent:

| State | Activation policy | Dock icon |
|---|---|---|
| No window open | `.accessory` | Hidden |
| Window open | `.regular` | Shown |

Opening the window (from the menu bar, from onboarding, or via ⌘⌥M-adjacent shortcut) promotes to `.regular`. Closing it demotes back to `.accessory`. Live monitoring and recording keep running in the background regardless of window state — the window is a view into the engine, not the engine's lifetime.

**Close vs. quit.** The red traffic light and ⌘W close (hide) the window; they do not quit the app or stop Live/Recording. The only way to fully quit is **Quit** in the menu bar popover. This avoids the classic mistake of a user closing what looks like "the app" and unknowingly killing background vocal reduction.

**Top-right switch.** A two-item segmented control, `Live` / `Practice`, sits in the window's title bar accessory area. Whichever tab isn't active still shows a small live-status dot next to the switch (accent-colored when Live is on) — so switching to Practice doesn't make Live's state invisible.

---

## 2. Menu bar popover (final, minimal scope)

Replaces the current `SettingsPopoverViewController` content entirely. No Mode/Intensity/Gain/Scope controls live here anymore — just status and two actions.

```
●  On                              <- status dot + text (mirrors window)
─────────────────────────
Live            [ toggle ]
Record          [ toggle ]
─────────────────────────
Open MinusOne…
Quit
```

- **Live toggle** — same ramp behavior as today (`toggleReduction()`), no teardown.
- **Record toggle** — starts/stops a system-audio recording without opening the window. On start, the menu bar icon switches to a distinct **Recording** state (see icon table) so there's always a glanceable confirmation. On stop, the clip is auto-titled (date/time) and dropped into the Practice library; if the window is open, it appears in the sidebar immediately.
- **Open MinusOne…** brings the window forward (promotes activation policy per §1).
- Right-click / ⌘⌥M still toggles Live directly without opening the popover, unchanged from today.

### Icon states (down from 6 to 5, mono-input state removed with Center Cut)

| State | Meaning | Color |
|---|---|---|
| Off | Idle / Live off | Menu-bar tint (template) |
| On | Live active | Brand accent |
| Warming up | Neural model loading | Cyan |
| Recording | Menu-bar-triggered record in progress | New — proposed: a small solid dot badge on the idle/on icon, not a full recolor, so it's readable simultaneously with Live's own state |
| Permission needed | Grant access in System Settings | Orange |
| Error | Tap for details | Red |

Recording can co-occur with Live on or off, which is why it's proposed as a badge rather than a fifth mutually-exclusive tint — worth a quick visual check once built.

---

## 3. Desktop app — Live tab

Full-width version of what the popover used to cram into ~190pt. Sections keep the same information architecture as today, minus Mode:

**Status** — large status line + dot, same semantics as the menu bar (`Off` / `On` / `Warming up` / `Permission needed` / `Error`), plus the primary on/off control (bigger hit target than the menu bar's, since this is the "settle in and configure" surface, not the "quick glance" one).

**Processing** — Intensity (0–100%) and Gain (0–12 dB, default 4.5) only. No mode picker. If the Neural model isn't installed, this whole section is replaced by the model-required state (§5).

**Capture** — Scope (All Apps / Custom), and if Custom, an upgraded app picker: a real checklist with app icons and names instead of today's single-selection popup-within-a-popup. This is the one place I'd add scope beyond a straight port — the current nested-popup picker is one of the more awkward interactions in the app, and there's finally room to fix it properly.

---

## 4. Desktop app — Practice tab

Keeps its current structure (sidebar library + deck) but restyled onto the same design system as Live, and with real fixes to the specific rough edges found in the source:

- **Toolbar** — Import and Record as matching, consistently-styled controls (today they mix a plain toolbar item with a `.texturedRounded` custom button — two different button languages side by side).
- **Spacing** — deck content currently pads at 24pt against the popover system's 15pt; unify on one spacing scale across the whole app.
- **Transport & mixer controls** — replace default `NSButton` bezels (Play/Loop/Solo/Mute) with the shared control style used elsewhere, not stock system buttons.
- **Per-stem color** — each stem gets a fixed identity color, used consistently for its mixer row, slider fill, and label:

| Stem | Color |
|---|---|
| Vocals | Brand accent `#E8475A` |
| Drums | Amber `#D98C3F` |
| Bass | Teal `#3F8FA8` |
| Other | Plum `#8A6FB0` |

  Vocals gets the brand accent deliberately — it's the stem the whole product is built around.

- **Empty state** — replace the single centered gray sentence with a real empty state: waveform-mark illustration (reuse the logo motif), plus two direct actions — "Import a clip" and "Record system audio" — instead of just prose telling the user what to do elsewhere.
- **Recording panel** (`RecordingTheme.swift`) — currently a deliberately distinct dark amber "tape deck" look, separate from the rest of the app. Open question below (§7) on whether to keep it as an intentional accent surface or fold it into the unified system now that the rest of the app is getting a real identity of its own.

---

## 5. Model-required gating

The Neural model is no longer optional — without it, Live has nothing to do. Onboarding needs to reflect that as a hard requirement, not a skippable step:

- First launch opens the window directly into a welcome/setup screen (not the menu bar).
- The Neural model download is presented as required to use Live, with clear size/time expectations (~200 MB, ~20 s compile).
- If a user backs out without downloading, the Live tab shows a persistent "Vocal reduction needs the Neural model" state with a Download CTA in place of the Intensity/Gain controls — never a toggle that silently does nothing.
- Practice mode already depends on the same model (`OfflineSeparationEngine` / `CoreMLSeparationModel`), so this is one gate serving both tabs, not two.
- System permission prompts (Microphone for BlackHole, System Audio Recording for Process Tap) stay contextual — requested at first real toggle attempt, not at cold launch, per existing behavior.

---

## 6. Shared design system

- **Brand accent** — `#E8475A`, as an `NSColor` asset (`brandAccent`), with a defined dark-appearance variant if contrast needs adjusting. Replaces every `.controlAccentColor` reference in status text, active icon states, primary buttons, and slider fills, in both the menu bar and the window.
- **Semantic status colors** — cyan (warming), orange (permission), red (error) carry over; re-check contrast against the new accent since they were originally chosen to read against system blue. Yellow (mono input) is retired along with Center Cut.
- **Spacing/typography** — extend `PopoverUI`'s metrics (or a renamed successor, since it's no longer popover-only) as the one source of truth for both the menu bar popover and the window, at two scales: compact (menu bar) and regular (window).
- **Stem palette** — the four colors in §4, defined once, reused anywhere a stem is represented.

---

## 7. Open items — need a decision before implementation

1. **`RecordingTheme.swift`'s amber "tape deck" look** — keep as a deliberately distinct surface (like a dedicated instrument view), or fold into the unified brand system? Leaning toward keeping it distinct but should be a conscious call, not inertia.
2. **Recording icon treatment** — badge-on-existing-icon vs. a fully separate icon state — worth a quick visual pass once built rather than deciding blind.
3. **Exact accent value** — `#E8475A` as extracted, or a slightly adjusted tone for UI-control legibility (text/dot at small sizes reads differently than a large icon fill)? Recommend testing both before locking it into an asset catalog.

---

## 8. Engineering scope (for translation into `TASKS.md`)

- Delete `CenterCancelDSP.swift`.
- Collapse `ProcessingMode` — remove `centerVocalCut` and `directListen`; either reduce to a single implicit Neural path or remove the enum and drive Live purely off on/off + Intensity/Gain.
- Strip mode-branching from `AudioEngine.swift` (confirmed touch points: DSP selection, `setProcessingMode`, and ~6 more call sites tied to `centerVocalCut`/`.monoInput`).
- Remove `.monoInput` from `AudioEngineState.swift` and all call sites; icon/status states drop to 5.
- New `MainWindowController` owning the Live/Practice segmented switch and the dynamic activation-policy behavior from §1.
- New `LiveTabViewController`, built from the content currently in `SettingsPopoverViewController`, minus Mode, plus the upgraded app checklist.
- Shrink `MenuBarController` + a new minimal `MenuBarPopoverViewController` to just §2's scope.
- Extend `PopoverUI` (or rename) into the shared design-system module referenced in §6.
- Update `README.md` and `TASKS.md` once the shape above is confirmed — README's Modes table and Quick Start "skip and use Center Cut" language are both now inaccurate.
