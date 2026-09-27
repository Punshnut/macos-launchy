# Scripts

This folder holds the public, unsigned build tooling for Launchy, the same tooling
you'd use to compile the app from source and run it locally.

- `build_app.sh` - builds a universal (Apple Silicon + Intel) `Launchy.app` from the
  Swift package, embeds Sparkle, and compiles the app icon. No signing or
  notarization involved, so the resulting app runs unsigned on your own machine.
- `publish_wiki.sh` - publishes the `wiki/` folder to the live GitHub wiki via
  `git subtree push`. See [CONTRIBUTING.md](../CONTRIBUTING.md#updating-the-wiki).

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full walkthrough, including setup
requirements and how to run the build.

Note that the maintainer's release tooling (code signing, notarization, DMG
packaging, Sparkle key rotation) is intentionally kept private and isn't part of
this repo. You don't need any of that to build and run Launchy for yourself or to
work on a contribution.
