# Launchy

Meet the featherweight glass launcher that feels tailor-made for macOS. Launchy hovers above your work, quietly indexes every app you already have, and opens them with one tap-no Dock clutter, no menu bars, just pure velocity.

## Designed for the Mac, inside and out

- **Instant index** - Scans `/Applications` and your user Applications directory, deduplicates bundles, and caches icons so Launchy is ready the moment it appears.
- **All signal, no chrome** - A translucent HUD panel, adaptive grid, and gentle pagination keep even the busiest libraries easy to browse.
- **Always within reach** - Launchy hides its Dock tile, floats across every Space, and activates apps via `NSWorkspace` to keep you in flow.
- **SwiftUI core** - 100% Swift + SwiftUI with compact files, making it simple to add filters, shortcuts, or theming.

Every feature that ships today-and tomorrow-stays free forever. The entire project is MIT licensed. Paid upgrades or donations are optional ways to support the roadmap, never a gate to existing functionality.

## Getting started

1. **Clone & open**
   ```bash
   git clone https://github.com/your-org/macos-launchy.git
   cd macos-launchy
   open Package.swift
   ```
2. **Build the app**
   ```bash
   ./build_app.sh
   ```
3. **Package & notarize**
   - `./build_dmg.sh` wraps the `.app` bundle inside a drag-and-drop DMG with install notes.
   - `./notarize_async.sh` signs, submits, and tracks notarization requests through `xcrun notarytool`.

Before distributing, update the bundle identifier, signing certificate, and notary profile so they match your Apple Developer Team.

## Make it yours

- Swap icons, adjust the HUD material, or extend `LauncherView` with search, favorites, or keyboard navigation.
- Layer in Spotlight or metadata filters by expanding `AppDiscoveryService`.
- Embed Launchy inside another product by reusing `LauncherWindowController` as a floating palette.

## Contributing

Pull requests, design sketches, and bug reports are always welcome. Launchy thrives on thoughtful UX polish and accessibility improvements-don't hesitate to share ideas.

## License & support

- **License:** MIT-use it, just keep the notice.
- **Support Launchy:** Optional paid upgrade tiers and donations help fund ongoing development, but they never lock down features you're already enjoying.

Thanks for building something delightful with Launchy.
