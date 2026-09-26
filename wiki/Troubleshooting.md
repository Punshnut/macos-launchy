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
it. Grant access under System Settings -> Privacy & Security -> Input
Monitoring, then try the hotkey again. Regular keys and letter/number
combinations don't need this permission.

## Launchy doesn't show up anywhere

If you've hidden both the Dock icon and the menu bar icon (a valid choice
under Startup & presence in Settings), the hotkey is your only way back in.
Double-check a hotkey is actually set under the Shortcuts tab, an unset
hotkey combined with both icons hidden means there's no way to summon
Launchy until you fix one of the two.

## My layout looks wrong after an update or a mistake

Use the reset option in Settings for a clean slate on tile positions,
custom names and hidden states survive a reset. If you need to go further
back, check for an automatic backup in
`~/Library/Application Support/Launchy/AutoBackup`, Launchy keeps the
latest 14, or restore from a manual export if you made one. See
[Organizing Your Apps](Organizing-Your-Apps) for how backups and resets
work.

## Still stuck?

Open an [issue](https://github.com/Punshnut/macos-launchy/issues), we're
happy to help, and if something in these docs is out of date or unclear,
a pull request fixing it is welcome too, see [Contributing](Contributing).
