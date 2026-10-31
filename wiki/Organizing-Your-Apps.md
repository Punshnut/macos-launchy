# Organizing Your Apps

Launchy's grid is meant to be shaped around how you actually work, not just
left as a raw list of everything installed. Here's what you can do with it,
and when each tool is the right one to reach for.

## Right-click for the full toolbox

Right-click any tile, folder, Dock icon, or menu bar icon to bring up a
context menu with the relevant actions: rename, hide, move, add or remove
folders, reveal in Finder, or reset gaps. This is the fastest way to get to
any single action without hunting through Settings.

A few actions are easy to miss:

- **Move to Page** sends an app or folder to a specific page, or lets you
  **Create New Page** at the beginning, at the end, or between two existing
  pages.
- **Right-clicking empty background** drops in a brand-new folder whenever
  you need one.
- **Folder Details** lists every app inside a folder, and **Rename Folder**
  lets you rename it in place. New folders start out as "unnamed" until you
  give them a name.

## Building folders

Hold `Option` while dragging one app onto another to create a folder, or
drop an app into an existing folder the same way. This is the move for
grouping things you use together, work apps, creative tools, games, so they
read as one tile instead of scattering across pages.

Folders are part of your saved arrangement, so a full reset removes them
(see "Resetting without losing your work" below). Launchy also keeps
automatic backups, so a grouping you care about is easy to get back.

## Rearranging without the chaos

Dragging a tile normally moves it and reshuffles everything around it,
which is what you want when you're actively rebuilding a layout. But if you
just want to swap two tiles' positions without disturbing anything else,
hold `Shift` while dragging. It's the difference between "rebuild this
section" and "just swap these two."

You're not limited to the page you started on: drag a tile to the edge of
the grid and hold it there and Launchy pages for you, so you can carry an
app straight from page 1 to page 4 without letting go. Drop it on empty
space and it lands there directly; drop it right onto another tile without
a modifier held and it reorders in, everything after it shifts down to make
room.

## Taking apps out of a folder

The quickest way: open the folder, right-click the app, and choose
**Remove from Folder**. The app lands on the page you're currently viewing.

You can also drag it out. Open a folder and drag an app to the edge of the
folder card, past a small threshold near the border, and release. Launchy
reads that as "take this back out" and returns the app to the root grid
instead of leaving it stranded inside the folder.

## Deleting a folder

Right-click a folder and choose **Delete Folder**. The folder disappears and
its apps go back onto the grid where the folder was. Nothing is hidden or
uninstalled, you just lose the grouping. The same menu has **Folder
Details**, which lists the apps inside.

## Changed your mind mid-drag?

Drop somewhere Launchy doesn't recognize as a valid target, outside the
grid, say, and nothing commits: the drag just ends and your layout is left
exactly as it was.

## Renaming

Some apps ship with names that aren't how you think of them. Right-click
any tile and rename it, the custom name is what shows in both the grid and
search, so it's worth doing for anything you regularly hunt for by a
different name than its default.

## Hiding what you don't need

Not every installed app deserves a spot in your daily grid. Use the Hidden
Apps tab in Settings to mute noisy or rarely-used entries, or to pin hidden
entries near the top so they're still one click away when you do need them.
This is also where you turn on scanning `~/Applications`, off by default,
if you keep apps there. See [Settings Overview](Settings-Overview) for the
full tab.

## Selecting more than one tile at once

See [Multi-Selection](Multi-Selection) for batch-moving or grouping several
apps in one go.

## Launchy remembers your page

If you leave Launchy on page 3 and hide it, reopening within about 90
seconds puts you right back on page 3, handy for a quick in-and-out without
paging over again. Leave it hidden longer than that and it settles back to a
"home" page in the background, so the next time you open it you're not
stuck picking up in the middle of a stale session.

By default that home page is page 1, but you can change this in Settings →
Visuals: pick a different fixed page, or tell Launchy to always stay on
whichever page you last viewed instead of reverting at all. See
[Settings Overview](Settings-Overview) for details.

## Dock menu

Right-click the Dock icon for a quick-launch menu of your apps and folders
without opening the full grid. By default standalone apps are listed first
alphabetically with folders grouped below them; you can turn this off in
Settings → Visuals if you'd rather see everything interleaved in a single
alphabetical list.

## Resetting without losing your work

If your grid gets into a state you don't like, **Reset icon arrangement**
(Settings → Shortcuts) gives you a clean slate. You choose how the new grid
is sorted (alphabetical, or in the order Launchy finds apps) and confirm
before anything happens. Custom names and hidden states stay intact across a
reset, so you're not throwing away the naming and hiding work you've
already done, just the positions. Folders are removed by a reset, so
export a backup first if you're attached to them.

## Backups, just in case

Launchy keeps quiet automatic backups of your arrangement (at most every 48
hours, only when something's actually changed) in
`~/Library/Application Support/Launchy/AutoBackup`, keeping the latest 14.
You can also export or restore a backup manually from Settings at any time,
handy before a big reorganization, or when moving to a new Mac.
