# Getting Started

## Installing

Grab the latest build from [Releases](https://github.com/Punshnut/macos-launchy/releases/latest),
move `Launchy.app` to your Applications folder, and open it. Every release
is notarized, so macOS will let it run without any extra steps.

Prefer to build it yourself instead? See [Contributing](Contributing).

## First launch

The first time Launchy opens, it scans `/Applications` and
`/System/Applications` for installed apps, builds an icon cache, and lays
out your first grid. On a typical Mac this takes a couple of seconds; on a
huge app library it might take a little longer the very first time. After
that, the cache keeps things instant.

If you keep apps in `~/Applications` too, turn that on in the Hidden Apps
tab of Settings, see [Settings Overview](Settings-Overview).

## Opening and closing Launchy

By default there's no preset hotkey, so the first thing worth doing is
opening Settings (`Cmd` + `,`) and setting one under the Shortcuts tab.
`Shift` + `Space` is a comfortable, Launchpad-style choice; `Ctrl` + `X` is
a solid alternative if that combo is already taken by something else.

Once a hotkey is set, tapping it opens Launchy instantly and tapping it
again closes it, so you can treat it like a light switch instead of
something you have to aim a cursor at.

If you'd rather not touch the keyboard, a hot corner works too: drag your
cursor into a corner of the screen and Launchy pops up.

## One permission you might need

If you want to use a media key (like volume or brightness) as part of your
hotkey and it doesn't trigger Launchy globally, macOS is likely blocking it.
Grant Launchy access under System Settings -> Privacy & Security -> Input
Monitoring, then try again. You only need to do this if you've chosen a
media key; regular keys and letter/number combos don't need it.

## Where to go next

Now that Launchy is open and reachable, [Fullscreen and Floaty Mode](Fullscreen-and-Floaty-Mode)
walks through the two ways to use it, and [Search](Search) covers the
fastest way to actually find and launch something once the grid is in
front of you.
