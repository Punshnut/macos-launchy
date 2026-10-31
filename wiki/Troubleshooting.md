# Troubleshooting

## Gatekeeper says the app is from an "unidentified developer"

This only comes up if you've built Launchy from source yourself, official
releases from [Releases](https://github.com/Punshnut/macos-launchy/releases/latest)
are notarized and open normally. A local build isn't signed or notarized,
so the first time you open it, right-click the app, choose "Open", and
confirm. You only need to do this once; after that it opens normally like
any other app. See [Contributing](Contributing) for the full build
walkthrough.

## A media key hotkey doesn't trigger Launchy

If you've set your show/hide hotkey to include a media key (volume,
brightness, playback) and it doesn't fire globally, macOS is likely
blocking it at the system level rather than Launchy failing to register
it. Grant access under System Settings → Privacy & Security → Input
Monitoring, then try the hotkey again. Regular keys and letter/number
combinations don't need this permission.

## Launchy doesn't show up anywhere

If you've hidden both the Dock icon and the menu bar icon (both toggles
live in Settings → Visuals), the hotkey is your only way back in. The
default `Cmd` + `Shift` + `Space` keeps working, but if you cleared it
under the Shortcuts tab, an empty hotkey combined with both icons hidden
means there's no way to summon Launchy until you fix one of the two.
Launching Launchy again from Finder or Spotlight also brings it back.

## My layout looks wrong after an update or a mistake

Use **Reset icon arrangement** in Settings → Shortcuts for a clean slate on
tile positions. Custom names and hidden states survive a reset. If you need to go further
back, check for an automatic backup in
`~/Library/Application Support/Launchy/AutoBackup`, Launchy keeps the
latest 14, or restore from a manual export if you made one. See
[Organizing Your Apps](Organizing-Your-Apps) for how backups and resets
work.

## The hotkey does nothing, or something else opens

Another app or a system feature may already own `Cmd` + `Shift` + `Space`
(some input-source switchers do). Record a different combo under Settings →
Shortcuts; `Ctrl` + `X` is a good fallback.

## An app I just installed isn't in the grid

Launchy watches your Applications folders and refreshes on its own, so new
apps normally appear within a moment. If an app lives in `~/Applications`,
make sure **Include user Applications folder** is on in the Hidden Apps
tab, and check that the app isn't ticked as hidden there.

## Reporting a bug? Attach the log

Launchy writes a small log of the current session to
`~/Library/Logs/Launchy/launchy.log` (capped at roughly 1 MB, and replaced
each time Launchy starts). If something misbehaves, reproduce it, then
attach that file to your [issue](https://github.com/Punshnut/macos-launchy/issues).
It contains no account data, since Launchy has no accounts.

## Still stuck?

Open an [issue](https://github.com/Punshnut/macos-launchy/issues), I'm
happy to help, and if something in these docs is out of date or unclear,
a pull request fixing it is welcome too, see [Contributing](Contributing).
