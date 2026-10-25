<p align="center">
  <img src="docs/icon.png" alt="MacAltTab" width="128">
</p>

<h1 align="center">MacAltTab</h1>

<p align="center"><a href="README.fr.md">Version française</a></p>

A Windows-style window switcher for macOS, with **Liquid Glass** and **no Screen Recording permission**.

## Why

`⌘ Tab` switches apps, not windows. With five VS Code projects or three Chrome windows, you end up hunting through them. AltTab solves this, but its window previews need Screen Recording, a permission that lets an app see everything on your screen.

MacAltTab shows app icons and window titles instead of previews. Accessibility is enough.

## Features

- **Every window, every desktop**: windows on other Spaces, minimized windows, hidden apps, and running apps with no window.
- **Global shortcut**: `⌥ ⇥` by default, customizable from the menu bar. `⇧` goes backwards.
- **Quick switch**: a fast `⌥ ⇥` jumps straight back to the previous window, without showing the grid.
- **Groups**: open windows, minimized windows and windowless apps on separate rows, with titles (optional).
- **Order**: most recently used, or alphabetical so tiles never move.
- **Sizes**: S, M or L.
- **Search**: type while the grid is open to filter by app or window title.
- **Browser and Terminal tabs**: Chrome, Safari and Terminal windows with several tabs show them in a side list. Click a tab, or use `⇧ ↓ ⇧ ↑` then `↩`. Close a tab with the `×` on hover or `⇧ ⌫`.
- **Native tabs merged**: Terminal or Finder windows with tabs show as one tile, not one per tab.
- **Window actions on hover**: close, minimize, full screen, quit, shown below the icon.
- **Dock badges**: unread counts (Mail, Messages…) on the tiles.
- **On release of `⌥`**: switch immediately, or keep the grid open until you click or press `↩` (default, to avoid switching by mistake).
- **Click the app** (Finder, launcher): opens the grid like the shortcut.
- **Launch at login**: one click in the menu.

## Keys

| Key | Action |
|---|---|
| `⌥ ⇥` / `⇧ ⌥ ⇥` | Next / previous |
| `← → ↑ ↓` | Move in the grid |
| `⇧ ↓` / `⇧ ↑` | Move in the tab list |
| `↩` | Go to the window (or tab) |
| `⎋` | Cancel |
| Letters | Filter |

## Permissions

| Permission | Why |
|---|---|
| Accessibility | List windows, read titles, focus a window, listen to `⌥` |
| Automation (Chrome, Safari, Terminal) | Read and select tabs. Optional: refuse it and the tab list is simply not shown |

No Screen Recording. No network access.

## How it works

- Windows of all Spaces come from `CGWindowListCopyWindowInfo` (no titles, so no permission needed), matched with their Accessibility elements.
- Windows on other Spaces are not returned by `kAXWindowsAttribute`: they are found once with `_AXUIElementCreateWithRemoteToken`, then cached.
- Focus uses `_SLPSSetFrontProcessWithOptions`, which also switches Space.
- These private APIs are the same ones used by AltTab.

## Install

Download the DMG from [Releases](../../releases), open it and drag MacAltTab to Applications. It is signed and notarized.

On first launch, allow MacAltTab in **System Settings → Privacy & Security → Accessibility**.

## Build

Requires macOS 26 and Xcode 26.

```sh
./build.sh               # build, sign, install in /Applications and launch
./build.sh --no-install  # build only (build/MacAltTab.app)
./build.sh --notarize    # also notarize (keychain profile "notary")
```

Without a Developer ID certificate, sign ad hoc: `SIGN_IDENTITY=- ./build.sh`.

## Release

Push a tag: `git tag v1.0.1 && git push origin v1.0.1`. GitHub Actions builds, signs, notarizes and publishes the DMG.

## License

GPL-3.0
