# Settings Overview

Open Settings with `Cmd` + `,`, or from the menu bar item. It's organized
into four tabs, here's what each one is for and when you'd reach for it.

## Visuals

The biggest tab, covering how the grid looks and behaves:

- **Launch at Login** and the **fullscreen ↔ floaty layout picker**, so you
  can set your preferred presentation mode directly instead of only toggling
  it with a hotkey.
- **Background style**: standard, light blur, transparent, or solid color
  (with a color palette for the solid option).
- **Icon size**: small, medium, or large. Large only applies in fullscreen;
  floaty mode caps at medium to keep the compact layout usable.
- **Paging direction**: horizontal or vertical, which also determines which
  way swipes and arrow keys move between pages — see
  [Gestures](Gestures) and [Keyboard Shortcuts](Keyboard-Shortcuts).
- **Return to page when reopened**: after Launchy has been hidden for a
  while, it can snap back to a fixed page you choose, or simply stay on
  whatever page you were last viewing.
- **Dock icon / menu bar icon** visibility toggles, and whether **folders
  sort after apps** in the Dock's right-click menu.
- **Auto-fill gaps**, so icons collapse upward automatically when you remove
  an app or rearrange the grid.

Worth a visit once your layout feels right and you want Launchy to match
your desktop aesthetic and habits.

## Hidden Apps

Where you manage what's visible in the main grid without uninstalling
anything: mute noisy or rarely-used apps, pin hidden entries near the top
so they're still quick to reach, and turn on scanning `~/Applications` if
you keep apps there (off by default, since most people don't). See
[Organizing Your Apps](Organizing-Your-Apps) for the reasoning behind
hiding vs. deleting.

## Shortcuts

Sets the launcher hotkey, the fullscreen <-> floaty toggle, and the hot
corner. Launchy stays reachable through this hotkey even if you've hidden
both the Dock icon and the menu bar icon elsewhere, so it's safe to tuck
Launchy away and rely entirely on the shortcut. See
[Keyboard Shortcuts](Keyboard-Shortcuts) for the full rundown of what you
can bind.

This tab also holds:

- **Reset arrangement**, which gives you a clean slate for tile positions
  while keeping the naming and hiding work you've already done. See
  [Organizing Your Apps](Organizing-Your-Apps) for what survives a reset
  and what doesn't.
- **Backup**: manual export and restore, alongside a note on the automatic
  backups Launchy keeps quietly in the background. See
  [Organizing Your Apps](Organizing-Your-Apps#backups-just-in-case) for
  details on where those live and how many are kept.

## About

Shows the app icon, version, and developer info, plus quick links to the
website, issue tracker, and support email. From here you can also revisit
the first-run introduction walkthrough at any time, or jump straight to the
GitHub repository. Launchy checks for updates automatically in the
background (via Sparkle); this is also where you'd notice a private/homemade
build badge if you're running one outside the official release channel.
