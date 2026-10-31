# Keyboard Shortcuts

Launchy is built to be usable entirely from the keyboard, useful whether
you just don't want to reach for a mouse, or you're navigating by feel
while your eyes are still on something else.

## The essentials

| Action | Shortcut |
| --- | --- |
| Show / hide Launchy | `Cmd` + `Shift` + `Space` (default, configurable in Settings) |
| Toggle fullscreen ↔ floaty | Not set by default, configurable in Settings |
| Launch top search result | `Return` |
| Move between pages | Left / right arrow keys |
| Jump to a specific page | `Control` + a number key (`1`-`9`, `0` for page 10) |
| Step back / close | `Escape` (see below) |
| Open Settings | `Cmd` + `,` |

Paging direction (and which arrow keys page you) follows the paging
orientation set in Settings → Visuals - horizontal by default, or vertical
if you've switched it. See [Settings Overview](Settings-Overview).

## Escape steps back, one layer at a time

`Escape` always undoes the most recent thing you did, so you can tap it
repeatedly without thinking about where you are:

1. Cancels a rename in progress.
2. Leaves multi-select mode.
3. Closes an open folder.
4. Clears the search field.
5. Hides Launchy.

## Picking a hotkey

The default show/hide hotkey is `Cmd` + `Shift` + `Space`. To change it,
open Settings → Shortcuts, click the field, and press the combo you want.
Press `Delete` to clear it, or **Reset** to bring the default back. If the
default clashes with something, `Ctrl` + `X` is a solid alternative.

Below it sits an optional second shortcut that flips between fullscreen and
floaty. It's empty until you record one, and you can clear it again at any
time.

You're not limited to letters and modifiers either: hotkeys can use
numbers, punctuation, arrow keys, function keys, keypad keys, and media
keys (volume, brightness, playback), in any combination with `Cmd`,
`Option`, `Shift`, and `Ctrl`. If you pick a media key and it doesn't
trigger Launchy globally, that's almost always a missing Input Monitoring
permission, see [Troubleshooting](Troubleshooting).

## Why bother with direct page jumps

If you keep a stable layout with, say, creative apps on page 2 and games on
page 4, `Control` + `2` or `Control` + `4` gets you there in one motion
instead of arrowing or swiping through pages in between. It's most useful
once your grid has settled into a layout you know by heart.

See also: [Gestures](Gestures) for the trackpad/mouse equivalents, and
[Settings Overview](Settings-Overview) for where all of this gets
configured.
