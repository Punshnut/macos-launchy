# Launchy

Launchy is a featherweight macOS launcher that feels like part of the system: fullscreen-first, ultra-fast, and absolutely minimal. It silently indexes every bundle you already have, keeps an edge-to-edge HUD ready on any Space (with an optional floaty palette), and launches apps with a single tap.

## Why Launchy?

- **Instant indexing** - Scans `/Applications` plus your user Applications directory, deduplicates bundles, and caches icons so the grid is populated the moment Launchy appears.
- **All signal, no chrome** - Uses a translucent HUD with adaptive grid and pagination to keep even dense libraries easy to scan.
- **Fullscreen by default** - Launchy opens as a fullscreen canvas for clean focus; switch to the floaty palette when you want something lighter that stays out of the way.
- **Floaty on tap** - Toggle (`Cmd`+`Option`+`F`) into the floating HUD that can live across every Space and optionally hide the Dock tile so it never steals focus.
- **Wheel + gesture paging** - Flick the trackpad, swipe horizontally, or spin the mouse wheel anywhere over the HUD to flip between pages without leaving home row.
- **Personalized controls** - Decide which bundles show up, pick the glass/transparent/solid background, keep Launchy visible on all Spaces, and toggle login+Dock/menu bar presence with one settings pane.
- **Pure SwiftUI** - A lean 100% Swift + SwiftUI stack means it's easy to theme, extend, or embed.
- **Free forever** - MIT licensed; donations only keep the roadmap humming.

## Floaty + Fullscreen

The latest drop brings two experience upgrades:

1. **Fullscreen standard** - Launchy starts in fullscreen so you get a wall-to-wall launcher immediately. It keeps the same glassy materials, icon scaling, and paging gestures.
2. **Floaty palette option** - Toggle (`Cmd`+`Option`+`F` or the menu bar command) into the floaty HUD that can ride along on every Space and disappear the moment you jump back into work. Hide the Dock icon for stealth or keep it handy for Option-clicking back in.

Wire these behaviors into your preferred shortcuts or automation tools to keep Launchy ready in any context.

## Wheel + Gesture Paging

Launchy listens for scroll wheel and trackpad gestures even when your pointer is idling over empty space. Horizontal swipes with a trackpad, Magic Mouse, or any device that reports precise deltas will accumulate until they cross a threshold, then flip to the next or previous page. Classic ratcheting mouse wheels also work vertically, which means every user can breeze through huge libraries without aiming for the Next/Previous buttons.

The gesture overlay is transparent and keeps hit-testing off, so you still interact with buttons, search, and icons exactly as before. Once Launchy fades out, the gesture monitor tears itself down so the rest of macOS never notices.

## Worth mentioning

- **Search everywhere** - The search field filters both display names and bundle identifiers, so weird dev tools are just a couple keystrokes away.
- **Per-app hiding** - The settings window lists every discovered bundle with its icon; uncheck anything you never want to see in the grid.
- **Login & Space controls** - Flip Launchy on at login, pin it to every Space, or keep it single-space without touching defaults commands.
- **Menu bar + shortcuts** - `Cmd`+`,` opens settings, `Cmd`+`Option`+`F` toggles layouts, and a dedicated Command Menu exposes reload + reset utilities for power users.
- **Fast icon caching** - `AppDiscoveryService` resolves and caches icons once, so switching layouts, paging, or relaunching is effectively instant even on large libraries.

## Usage tips

- Assign Launchy to a hotkey or gesture via your favorite automation utility.
- Launchy opens fullscreen by default; toggle the floaty palette (or shortcut) when you want it to hover instead.
- Scroll, swipe, or nudge the mouse wheel anywhere over the HUD to flip pages instantly.
- Search, favorites, or metadata filters can be layered on top of the existing grid with minimal SwiftUI code.

## Make it yours

- Customize `LauncherView` to add keyboard navigation, filters, or different grid densities.
- Extend `AppDiscoveryService` if you want to watch additional directories or surface metadata-based filters.
- Reuse `LauncherWindowController` as a floating palette inside another product; the floaty and fullscreen behaviors are reusable.

## License & support

- **License:** MIT. Use it anywhere, just keep the notice.
- **Support Launchy:** Optional upgrades or donations are a nice signal boost but never gate existing features.

Thanks for helping Launchy stay lightweight and delightful.
