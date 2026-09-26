# SimpleShot

<p align="center">
  <img src="assets/logo.svg" alt="SimpleShot logo" width="160"/>
</p>

<p align="center">
  <b>A minimal, native macOS screenshot and annotation tool.</b><br>
  Capture, mark up, copy. Runs entirely offline — no accounts, no uploads, no updater.
</p>

<p align="center">
  <a href="https://github.com/zkmn73/SimpleShot/releases/latest">Download</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="PRIVACY.md">Privacy</a> · <a href="SECURITY.md">Security</a>
</p>

---

## Install

**Homebrew (recommended):**

```bash
brew trust zkmn73/tap
brew install --cask zkmn73/tap/simpleshot

# if you want it installed to your own Applications folder instead of the system-wide one
brew install --cask zkmn73/tap/simpleshot --appdir=~/Applications
```

Recent Homebrew versions (7.x) only load casks from third-party taps you have trusted, which is what `brew trust` does. The cask also uses `postflight_steps`, so it needs a Homebrew version that supports it.

Upgrade with `brew upgrade --cask simpleshot`, remove with `brew uninstall --cask --zap simpleshot`.

**Manual:** download `SimpleShot.dmg` from [Releases](https://github.com/zkmn73/SimpleShot/releases) and drag the app to `/Applications`. Builds are not notarized, so macOS may block the first launch: right-click the app and choose Open, or run `xattr -dr com.apple.quarantine /Applications/SimpleShot.app`.

> Because builds are ad-hoc signed, macOS treats every new version as a new app. Grant **Screen Recording** permission again after upgrading.

## Quick start

1. Launch SimpleShot — it lives in your menu bar.
2. Press `Cmd+Shift+X` and drag to select a region.
3. Pick a tool from the toolbar to annotate (Move is the default: drag inside the selection to reposition it), then press `Cmd+C` to copy or `Cmd+S` to save.
4. Press `Esc` to cancel.

## Features

**Capture**
- Region, full-screen and quick capture from global hotkeys or the menu bar
- Window snap: hover a window and click to capture it exactly (`Tab` toggles snap, `F` selects the full screen)
- Boundary snap to strong edges while dragging (hold `Option` to bypass)
- Exact pixel size and aspect-ratio presets, editable while selecting
- Multi-monitor capture, optional capture delay (3/5/10/30 s); the mouse cursor is never captured
- Scroll capture: select a region and scroll, SimpleShot stitches it into one tall image
- OCR & QR: extract text with Apple Vision and read QR codes
- Open an image file or the clipboard image in the editor

**Annotate**
- Pencil (optional smoothing), Line, Arrow (5 styles), Rectangle, Ellipse, Marker, Text (rich formatting), Number (1 / I / A / a)
- Censor: pixelate, blur, solid fill or smart erase, with automatic redaction of emails, phone numbers, card numbers, keys, faces and people
- Color Picker
- Click any annotation to move, resize, rotate, restyle or delete it; hold `Space` while drawing to reposition; snap guides; full undo/redo

**Output**
- Copy to clipboard, save to a folder (default `~/Downloads`), or ask where to save
- PNG, JPEG, HEIC and WebP, adjustable quality, optional 1x downscale on Retina
- Filename templates (`{date}`, `{window}`, `{random}` and more)
- Standalone editor window with crop, flip, zoom, Add Capture (compose several regions) and paste

**Settings**
- Launch at login, hide the menu bar icon, rebindable hotkeys
- Export and import settings as a JSON file
- `simpleshot://` URL scheme for Raycast, Alfred and Shortcuts

<details>
<summary><b>Keyboard shortcuts</b></summary>

**Global hotkeys** (rebindable in Settings > Shortcuts)

| Shortcut      | Action                                 |
| ------------- | -------------------------------------- |
| `Cmd+Shift+X` | Capture area                           |
| `Cmd+Shift+F` | Capture full screen                    |
| `Cmd+Shift+S` | Quick capture (uses your Enter action) |
| `Cmd+Shift+T` | Capture OCR & QR                       |
| unassigned    | Scroll capture, open from clipboard    |

**During capture**

| Shortcut                    | Action                                         |
| --------------------------- | ---------------------------------------------- |
| `Enter`                     | Confirm (save and/or copy, per Settings)       |
| `Cmd+C` / `Cmd+S`           | Copy / save                                    |
| `Cmd+Z` / `Cmd+Shift+Z`     | Undo / redo                                    |
| `Esc`                       | Cancel or close a popover                      |
| `Delete`                    | Remove the selected annotation                 |
| `Tab`                       | Toggle window snap                             |
| `F`                         | Select the full screen (in snap mode)          |
| `Shift` (while drawing)     | Constrain to straight lines and perfect shapes |
| `Space` (while drawing)     | Reposition the shape without resizing          |
| Right-click on line / arrow | Add an anchor point                            |

</details>

<details>
<summary><b>URL scheme</b></summary>

Enable it in Settings > General.

| URL                                | Action                        |
| ---------------------------------- | ----------------------------- |
| `simpleshot://capture`             | Start area capture            |
| `simpleshot://capture-fullscreen`  | Capture the full screen       |
| `simpleshot://quick-capture`       | Quick capture                 |
| `simpleshot://ocr`                 | Capture area and read text/QR |
| `simpleshot://scroll-capture`      | Start scroll capture          |
| `simpleshot://settings`            | Open Settings                 |
| `simpleshot://open?file=/path.png` | Open an image in the editor   |

</details>

## Permissions and privacy

- **Screen Recording** is required to capture. macOS asks on first use.
- **Accessibility** is only needed for scroll capture and for snapping to individual interface elements.
- SimpleShot has no network access and sends nothing anywhere. Captures stay on your Mac unless you save or copy them yourself. See [PRIVACY.md](PRIVACY.md).

## Build from source

Requires Xcode 26 or later.

```bash
git clone git@github.com:zkmn73/SimpleShot.git
cd SimpleShot
xcodebuild -scheme macshot -configuration Release \
  DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic build
scripts/run-tests.sh      # headless unit tests
```

Releases are built by GitHub Actions when a `v*.*.*` tag is pushed; see [CLAUDE.md](CLAUDE.md#releasing).

## Requirements

macOS 12.3 (Monterey) or later.

## Credits and license

SimpleShot is a slimmed-down fork of [macshot](https://github.com/sw33tLie/macshot) by sw33tLie. Licensed under [GPLv3](LICENSE).
