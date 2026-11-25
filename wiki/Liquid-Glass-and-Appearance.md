# Liquid Glass and Appearance

On macOS 26 and later, Launchy uses Apple's Liquid Glass design for its
Settings window and, if you turn it on, for folders. On older macOS versions
Launchy keeps its classic frosted look, so nothing is missing and there is
nothing to configure.

## What changes where

| Part of Launchy | macOS 13 to 25 | macOS 26 and later |
|---|---|---|
| Settings window | Frosted panels and standard controls | Liquid Glass panels, tab bar, buttons, switches, sliders, steppers and menus |
| Folders (grid icons and the opened folder) | Classic frosted look | Classic look by default, Liquid Glass when you turn on **Liquid Glass folders** |
| Search bar and floaty panel | Frosted material | Liquid Glass |

## Turning on Liquid Glass folders

1. Open Settings with `Cmd` + `,` and go to the **Visuals** tab.
2. Turn on **Liquid Glass folders**. The switch only appears on macOS 26 or
   later.
3. Open your launcher. Folders now use the same glass as the rest of macOS.

It is off by default so your folders keep the look you already know. Turn the
switch off again at any time to go back.

## Following your macOS settings

Launchy does not use its own blur or tint for Liquid Glass. It asks macOS to
draw the glass, so it follows what you choose in System Settings:

- **Appearance → Liquid Glass** (Clear or Tinted, and on macOS 27 any new
  material and effect options): the Settings window and Liquid Glass folders
  change with it.
- **Accessibility → Display → Reduce Transparency**: glass surfaces become
  solid, and folders return to the classic look.
- **Accessibility → Display → Increase Contrast**: glass surfaces get a
  clear outline.

## Good to know

- The setting is stored on this Mac only and is not part of a backup export.
- Glass looks best over a calm background. Over a very busy or very bright
  wallpaper, a **Solid color** or **Light blur** background
  (see [Backgrounds and Colors](Backgrounds-and-Colors)) can read better.
- Something not looking right? See [Troubleshooting](Troubleshooting).
