# Launchy

Launchy is a featherweight macOS launcher that feels like part of the system: floaty, ultra-fast, and absolutely minimal. It silently indexes every bundle you already have, keeps a translucent HUD ready on any Space, and launches apps with a single tap.

## Why Launchy?

- **Instant indexing** - Scans `/Applications` plus your user Applications directory, deduplicates bundles, and caches icons so the grid is populated the moment Launchy appears.
- **All signal, no chrome** - Uses a translucent HUD with adaptive grid and pagination to keep even dense libraries easy to scan.
- **Floaty-first design** - The default HUD floats above every Space, keeps blur + shadow grounding, and can optionally hide the Dock tile so it never steals focus.
- **Fullscreen focus** - Switch (`Cmd`+`Option`+`F`) into the classic fullscreen canvas for demos or single-monitor work; Launchy stretches edge-to-edge with matching materials.
- **Wheel + gesture paging** - Flick the trackpad, swipe horizontally, or spin the mouse wheel anywhere over the HUD to flip between pages without leaving home row.
- **Personalized controls** - Decide which bundles show up, pick the glass/transparent/solid background, keep Launchy visible on all Spaces, and toggle login+Dock/menu bar presence with one settings pane.
- **Pure SwiftUI** - A lean 100% Swift + SwiftUI stack means it's easy to theme, extend, or embed.
- **Free forever** - MIT licensed; donations only keep the roadmap humming.

## Floaty + Fullscreen Update

The latest drop brings two experience upgrades:

1. **Floaty HUD by default** - Launchy launches as a floating palette so it never steals focus, can ride along on every Space, and disappears whenever you jump back into work. Hide the Dock icon for peak stealth or keep it around when you want to Option-click back in.
2. **One-tap fullscreen** - Toggle fullscreen (`Cmd`+`Option`+`F` or the menu bar command) to flood the screen with the same glassy interface, perfect for single-display setups or live demos. You get the same blur/backdrop consistency, icon scaling, and paging gestures without any special wiring.

Wire these behaviors into your preferred shortcuts or automation tools to keep Launchy ready in any context.

## Wheel + Gesture Paging

Launchylistens for scroll wheel and trackpad gestures even when your pointer is idling over empty space. Horizontal swipes with a trackpad, Magic Mouse, or any device that reports precise deltas will accumulate until they cross a threshold, then flip to the next or previous page. Classic ratcheting mouse wheels also work vertically, which means every user can breeze through huge libraries without aiming for the Next/Previous buttons.

The gesture overlay is transparent and keeps hit-testing off, so you still interact with buttons, search, and icons exactly as before. Once Launchy fades out, the gesture monitor tears itself down so the rest of macOS never notices.

## Worth mentioning

- **Search everywhere** - The search field filters both display names and bundle identifiers, so weird dev tools are just a couple keystrokes away.
- **Per-app hiding** - The settings window lists every discovered bundle with its icon; uncheck anything you never want to see in the grid.
- **Login & Space controls** - Flip Launchy on at login, pin it to every Space, or keep it single-space without touching defaults commands.
- **Menu bar + shortcuts** - `Cmd`+`,` opens settings, `Cmd`+`Option`+`F` toggles layouts, and a dedicated Command Menu exposes reload + reset utilities for power users.
- **Fast icon caching** - `AppDiscoveryService` resolves and caches icons once, so switching layouts, paging, or relaunching is effectively instant even on large libraries.

## Quick start

1. **Clone & open**
   ```bash
   git clone https://github.com/your-org/macos-launchy.git
   cd macos-launchy
   open Package.swift
   ```
2. **Build the `.app`**
   ```bash
   ./build_app.sh
   ```
3. **Package or notarize (optional)**
   - `./build_dmg.sh` wraps the bundle into a drag-and-drop DMG.
   - `./notarize_async.sh` signs and submits via `xcrun notarytool`, then polls for the result.

Before shipping, make sure the bundle identifier, signing certificates, and notary profile match your Apple Developer Team.

## Usage tips

- Assign Launchy to a hotkey or gesture via your favorite automation utility.
- Hover for floaty mode, tap the fullscreen toggle (or shortcut) for wall-to-wall Launchy.
- Scroll, swipe, or nudge the mouse wheel anywhere over the HUD to flip pages instantly.
- Search, favorites, or metadata filters can be layered on top of the existing grid with minimal SwiftUI code.

## Build & versioning

- **Current version:** `v0.1a`
- Update the `APP_VERSION` constant near the top of `build_app.sh` when you cut a new release; the script rewrites `CFBundleShortVersionString` and `CFBundleVersion`.
- Scripts expect modern Xcode toolchains and `xcrun` utilities available in your `PATH`.

## Make it yours

- Customize `LauncherView` to add keyboard navigation, filters, or different grid densities.
- Extend `AppDiscoveryService` if you want to watch additional directories or surface metadata-based filters.
- Reuse `LauncherWindowController` as a floating palette inside another product; the floaty and fullscreen behaviors are reusable.

## Contributing

Pull requests, design sketches, and bug reports are very welcome-polish and accessibility ideas especially. Open an issue if you want to bounce ideas before building.

## License & support

- **License:** MIT. Use it anywhere, just keep the notice.
- **Support Launchy:** Optional upgrades or donations are a nice signal boost but never gate existing features.

Thanks for helping Launchy stay lightweight and delightful.
