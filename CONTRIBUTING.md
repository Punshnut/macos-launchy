# Contributing to Launchy

Thanks for wanting to dig into Launchy. Most people just want the app, so grab a
build from [Releases](https://github.com/Punshnut/macos-launchy/releases/latest)
and let Sparkle keep it updated. This guide is for anyone who wants to build
from source: to test an unreleased change, poke around the code, or send a pull
request.

## Getting set up

You'll need:

- A Mac running macOS 13 (Ventura) or later.
- Xcode Command Line Tools, or a recent version of Xcode. If you don't have
  either yet: `xcode-select --install`.
- That's it. Launchy is built with Swift Package Manager, so there's no
  `.xcodeproj` to open and no Apple Developer account needed for a local,
  unsigned build.

Clone the repo and you're ready:

```bash
git clone https://github.com/Punshnut/macos-launchy.git
cd macos-launchy
```

## Project layout

- `Package.swift` - the Swift package definition. Targets macOS 13+, pulls in
  [Sparkle](https://github.com/sparkle-project/Sparkle) for auto-updates.
- `App/` - the app's Swift sources.
- `Resources/` - `Info.plist`, localizations (`*.lproj`), and `Launchy.icon`
  (the app icon, built with Icon Composer).
- `scripts/` - public build tooling, see [scripts/README.md](scripts/README.md).

## Fast dev loop

For quick iteration while you're working on a change, you don't need the full
bundled app. Just build and run the package directly:

```bash
swift build
swift run
```

Or open the folder in Xcode or VS Code (with the Swift extension) and use
their built-in build/run support. Either way, you get fast rebuilds without
going through the icon and bundling steps below.

## Building the real app

When you want an actual `Launchy.app` you can double-click and run like a
normal user would, use the build script:

```bash
./scripts/build_app.sh
```

This builds both architectures, combines them into one universal binary,
embeds the Sparkle framework, copies over the localizations, compiles the app
icon, and drops a finished `Launchy.app` in the project root. It takes a
minute or two. Set `VERBOSE=1` if you want to see the full build output, or
`ARCHES=arm64` to build a single architecture for a faster local iteration.

Since this build isn't signed or notarized, macOS Gatekeeper will flag it the
first time you open it. That's expected: right-click the app, choose "Open",
and confirm. You only need to do this once.

## Updating the Wiki

The [project wiki](https://github.com/Punshnut/macos-launchy/wiki) is published from the `wiki/` folder in this repo, so doc changes go through a normal PR like any other change:

1. Edit the relevant `wiki/*.md` file(s) and open a PR against `dev` as usual.
2. Once merged, publish it to the live wiki:
   ```bash
   ./scripts/publish_wiki.sh
   ```
   This adds a one-time `wiki` git remote pointing at `macos-launchy.wiki.git` if it isn't there yet, then pushes `wiki/` to it via `git subtree push`.

## Sending a pull request

- Branch off `dev`, not `main`.
- Keep pull requests focused on one change; it makes them much easier to
  review.
- Launchy is licensed under AGPL-3.0. By submitting a contribution, you agree
  it's released under the same license as the rest of the project.
- If you used AI tools while working on your contribution, please read
  [AI_POLICY.md](AI_POLICY.md) first.

## Questions or stuck?

Open an issue, we're happy to help. And if anything in this guide is out of
date or confusing, a pull request fixing it is welcome too.
