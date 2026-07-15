# Subgroup Cycle

Adds a StarCraft 2-style "subgroup cycling" behavior to control groups: select a mixed
control group (e.g. frigates + destroyers all bound to `1`), then press **Tab** (current
key, see "Design notes" below) to cycle through selecting just one unit type at a time,
in the same order they appear in the control-group panel. Press the control group's
number key again to go back to selecting everyone.

## Why

BAR's native selection tools (double-click, "select all matching units", etc.) let you
narrow a mixed selection down to one type, but there's no single key that cycles through
the types already in your current control group the way SC2's Tab does. This widget adds
that specific behavior.

## Usage

1. Bind a mixed group of unit types to a control group as usual (e.g. press `1`).
2. With that group selected, press **Tab**:
   - 1st press -> selects only the first unit type in the group
   - 2nd press -> selects only the second unit type
   - ... and so on, wrapping back to the first type after the last
3. Press the control group's number key again to reselect the whole group.
4. Click elsewhere, deselect, or select something else entirely, and the cycle resets
   automatically the next time you use it.

If your current selection only contains a single unit type to begin with, Tab is left
untouched, so it won't interfere with anything else Tab is normally used for.

> **If you use the GRID keyset:** Tab is bound there by default to "Select Commander",
> which conflicts with this widget. See "Design notes" below -- you'll likely need to run
> `/unbindkeyset tab` before cycling works.

## Visual overlay

While you're mid-cycle, a small row of icons appears just above the control-groups panel
(the 0-9 buttons), showing every unit type in the group with the currently active one
highlighted. This exists because narrowing the live selection down to one type would
otherwise make BAR's native "Info" panel look identical to a simple single-type
selection, with no indication that you're cycling through a larger group. The overlay:

- Is anchored to the control-groups panel's own position, so it lines up correctly
  whether the build menu (and therefore the control-groups panel) is docked at the
  bottom or on the left.
- Sizes itself to the same height as the control-groups panel, and only as wide as it
  needs to be to show one square icon per unit type (it is not limited to the width of
  the control-groups panel itself, and can extend further if the group has many types).
- Disappears automatically once you leave the cycle.

## Design notes

**Tab is hardcoded, not read from a keybind.** Custom widget hotkeys aren't
currently rebindable through BAR's `uikeys.txt` system, so this widget listens
for Tab's raw key code directly. Two known consequences:
- **If you use the GRID keyset (the default), Tab is already bound to "Select
  Commander" there, and this conflicts with cycling.** In testing, the widget
  does not reliably override that native binding on its own -- Tab ends up
  focusing the Commander instead of cycling. **You need to free up Tab first**,
  either live in chat with `/unbindkeyset tab`, or permanently by adding
  `unbindkeyset tab` to your own `uikeys.txt`. (The Legacy keyset binds
  Commander selection to Ctrl+C instead, so this conflict doesn't apply there.)
  If you still want quick Commander selection after unbinding Tab, rebind that
  action to a spare key in the same file.
- The cycle key itself can't be changed without editing this file. A proper
  fix would need BAR to expose a way for widgets to register a rebindable
  action; until then this is a known limitation rather than a design choice.

**The overlay doesn't modify or replace `gui_info.lua`.** The cleanest result
would be for BAR's own "Info" panel to natively support this kind of subgroup
highlighting. Editing that file directly was considered, but it's a large,
intricate piece of core game code, and modifying it isn't realistic to
maintain as an external community widget. Drawing a small independent overlay
next to the control-groups panel instead was simpler to build and safer to
maintain, at the cost of "Info" and this overlay being two separate visual
elements rather than one unified panel. The end result reads clearly enough
in practice that this trade-off seemed acceptable.



## Notes / limitations

- The cycle order matches BAR's own global unit ordering (the same list the selection
  panel itself uses internally), read live via `WG['buildmenu'].getOrder()`.
- The overlay is drawn with `WG.FlowUI.Draw.Unit` / `WG.FlowUI.Draw.Element`, the same
  primitives BAR's own `gui_info.lua` and `gui_unitgroups.lua` use, so it should stay
  visually consistent with the rest of the UI.
- This widget selects units (`Spring.SelectUnitArray`), so per BAR's fair-play rules it
  will not be usable in ranked/matchmaking games unless/until it's part of the officially
  bundled widget set. It works normally in skirmish and custom lobby games.
