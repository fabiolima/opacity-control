# Opacity Control

Floating panel to set the focused window's opacity from a slider.

## Install

Omarchy has no manifest field or install hook for either of these, so both
are manual, one-time steps for whoever installs this plugin:

1. Enable it: `omarchy plugin enable opacity-control` (skip this if you
   installed with `omarchy plugin add ... --enable`).
2. Add a keybinding — this plugin has no default one — by adding this line
   to `~/.config/hypr/bindings.lua`:

   ```lua
   o.bind("ALT + O", "Window opacity", "omarchy-shell shell toggle opacity-control")
   ```

   Pick any other key combo instead of `ALT + O` if you'd rather; check
   `omarchy menu keybindings --print` first in case it's already bound to
   something.

`Alt+O` (or whatever you bound) then opens the panel over the currently
focused window.

## Keys

| | |
|---|---|
| drag / scroll | set opacity |
| `↑` `↓` / `k` `j` | ±1% |
| `Enter` / `Esc` | close |

## How it works

The slider dispatches Hyprland's `hl.dsp.window.set_prop({ prop = "opacity",
value = ..., window = "address:..." })` (via `hyprctl dispatch`), addressed
explicitly to the window that was focused when the panel opened — not the
dispatcher's "active window" default, since this panel itself grabs
exclusive keyboard focus once shown, which "active" can no longer be trusted
to see past.

The value sent is compensated, not the raw slider percentage: Hyprland
always multiplies `decoration:active_opacity`/`inactive_opacity` (the
theme's/Omaland's global dimming) into a window's rendered opacity,
`override` or not, so sending the slider value as-is would cap out at
whatever ceiling is set. Dividing by that ceiling first — read once when the
panel opens — cancels it back out, so 100% on the slider really means fully
opaque regardless of Omaland's settings.

This is a runtime property, not a window rule: it isn't written to any
config file, so it lasts until Hyprland next re-evaluates that window's
rules (e.g. on focus change or reload).

```
manifest.json    plugin declaration (kind: panel)
Panel.qml        panel window, slider, hyprctl dispatch
```
