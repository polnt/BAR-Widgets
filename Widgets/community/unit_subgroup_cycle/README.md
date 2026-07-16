# Subgroup Cycle

Adds a StarCraft 2-style "subgroup cycling" behavior to control groups: select a mixed
control group (e.g. frigates + destroyers all bound to `1`), then press **Tab** (default
key, rebindable -- see "Design notes" below) to cycle through selecting just one unit type
at a time, in the same order they appear in the control-group panel. Press the control
group's number key again to go back to selecting everyone.

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

If your current selection only contains a single unit type to begin with, pressing the
cycle key is a no-op.

> **If you use the GRID keyset:** Tab is bound there by default to "Select Commander",
> which would otherwise conflict with this widget. The widget frees Tab up automatically
> while it's enabled (see "Design notes" below) -- no manual `/unbindkeyset` needed. If
> you want quick Commander selection back, rebind `selectcomm focus` to a spare key in
> your own `uikeys.txt`. If you instead rebind `subgroup_cycle` to a different key
> yourself, the widget notices and leaves Tab (and Commander selection) untouched.

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

**The cycle key is a real, rebindable action, not a hardcoded key.** The widget
registers a named action (`subgroup_cycle`) via `widgetHandler:AddAction`, the
same mechanism BAR's other rebindable widgets use (e.g. `gui_ping_wheel.lua`'s
`ping_wheel_on`). If you'd rather use a different key, add a line like
`bind <key> subgroup_cycle` to your own `uikeys.txt` (or run it live via
`/bind <key> subgroup_cycle`).

**A custom bind needs the widget to reinitialize before it's picked up.** The
"has the player already bound this?" check (below) only runs once, inside
`widget:Initialize`. Editing `uikeys.txt` on disk doesn't do anything live -- the
engine only reads that file at startup, or when you explicitly `/keyload` it -- and
even binding live via `/bind <key> subgroup_cycle` mid-game won't retroactively free
Tab if the widget already claimed it earlier that session. So after setting your own
bind, either restart the game, or toggle the widget off and back on (or `/luaui
reload`) so `widget:Initialize` runs again and sees the new binding.

**Tab is claimed automatically on `widget:Initialize`, but only as a default.**
BAR's GRID keyset binds `selectcomm focus` ("Select Commander") to plain Tab in its
own `uikeys.txt`, loaded before this widget ever runs. Actions bound to the same
keyset are tried in the order they were bound, first match wins -- so that native
binding always wins the race against anything a widget registers later, regardless
of whether it's a proper action or a raw key listener. Before touching anything, the
widget checks `Spring.GetActionHotKeys("subgroup_cycle")`: if you've already bound
`subgroup_cycle` to a key yourself (in your own `uikeys.txt`), it leaves Tab and
your binding alone entirely -- no unbinding, no default. Only when nothing's been
configured does it snapshot whatever's currently on Tab, clear it with
`/unbindkeyset tab`, and bind Tab to `subgroup_cycle` itself. On `widget:Shutdown`
(the widget being disabled/removed), it restores exactly what it found -- so on GRID,
Tab goes back to selecting the Commander the moment the widget turns off, but only if
it was the one that claimed Tab in the first place. All of this only touches the
current session's live keyset; your `uikeys.txt` file itself is never modified. (The
Legacy keyset binds Commander selection to Ctrl+C instead, so none of this applies
there -- Tab has nothing to free up.)

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
