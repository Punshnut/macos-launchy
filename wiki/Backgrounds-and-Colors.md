# Backgrounds and Colors

Launchy picks its background and text colors so labels stay readable. This
page explains what you will see in each mode, and why. Set the style under
Settings → Visuals → **Background style**.

## At a glance

| Background style | Floaty | Fullscreen | Label color |
|---|---|---|---|
| **Standard** | Follows macOS: light blur in Light Mode, dark blur in Dark Mode | Always a dark blur of your desktop, in both Light and Dark Mode | Floaty: dark text on light, white text on dark. Fullscreen: always white |
| **Light blur** | Light blur | Light blur | Always dark text, whatever macOS is set to |
| **Solid color** | Your chosen color | Your chosen color | White on dark colors, dark on light colors |
| **Transparent** | Your desktop, no blur | Your desktop, no blur | Picked from your wallpaper brightness and macOS Light/Dark (see below) |

## Standard

- **Floaty** matches macOS. Switch between Light and Dark Mode and the
  panel fades between the two looks in about a quarter of a second. The
  background, labels, search bar and page dots all change together.
- **Fullscreen** is meant to feel like the old Launchpad: just your blurred
  desktop, with no light tint mixed in. It stays dark in Light Mode too, so
  its labels are always white.

## Light blur

A light, frosted look with dark text. It is a fixed choice, so it does not
change with macOS Light/Dark Mode.

## Solid color

Text color depends on how bright the color you picked is. Dark colors such as
Graphite or Indigo get white text. Light colors such as Yellow or Mint get
dark text.

## Transparent

Nothing is drawn behind the icons, so Launchy has to guess what is behind
them. It reads your desktop wallpaper and estimates how bright it is:

- **Dark wallpaper**: white labels.
- **Bright wallpaper**: dark labels.
- **Dark Mode** nudges the decision toward white labels, and **Light Mode**
  toward dark labels. This helps with wallpapers that change through the day.
- **Close calls**: if the wallpaper is somewhere in the middle, Launchy keeps
  the previous choice so labels don't flicker, and adds a stronger soft
  shadow behind the text so it stays readable either way.
- **Can't read the wallpaper** (some dynamic wallpapers): Launchy follows
  macOS: white labels in Dark Mode, dark labels in Light Mode.

The wallpaper is read from its file, so no Screen Recording permission is
needed. It is re-checked when you switch Space or change displays. It is
measured as a whole, so a busy or half-bright wallpaper can still leave a
label hard to read in one spot.

## Folders

Opened folders always use a dark card, in every style, so folder titles,
icon names and page arrows are always white.

## Troubleshooting

- *Fullscreen looks dark in Light Mode.* That is intended for Standard. Pick
  **Light blur** if you want a light fullscreen.
- *Labels are hard to read in Transparent.* Try Standard or Solid, or a
  less busy wallpaper.

See also [Fullscreen and Floaty Mode](Fullscreen-and-Floaty-Mode) and
[Settings Overview](Settings-Overview).
