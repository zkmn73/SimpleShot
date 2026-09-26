# Changelog

SimpleShot is a slimmed-down fork of [macshot](https://github.com/sw33tLie/macshot). The upstream history up to 4.3.0-beta.1 is in the [macshot changelog](https://github.com/sw33tLie/macshot/blob/main/CHANGELOG.md).

## [1.4.1] - 2026-09-26

### Fixed

- **Delayed capture could get permanently stuck** — if no display was available when the countdown was about to appear (all displays asleep, or a headless session), the app never cleared its "capturing" flag, silently blocking every later capture until relaunch. It now attempts the capture directly instead of waiting on a countdown it can't show.
- **Scroll capture's frozen-header detection could lock in a bad guess** — a bug left the second confirming sample unreachable, so a single misjudged frame could permanently crop the wrong amount off the top of every stitched frame for the rest of the capture. The second-sample confirmation now actually runs.

## [1.4.0] - 2026-09-26

One toolbar, and Move as the default tool.

### Changed

- **One toolbar** — the right-hand toolbar was merged into the bottom one: Copy, Save, OCR, Scroll Capture, Open in Editor and Cancel now sit at the right end of the same bar, after a divider. The editor's bar is the same minus the overlay-only Scroll Capture, Open in Editor and Cancel.
- **Move is the default tool** — a new Move button is first in the toolbar and active by default. Dragging inside the selection moves the whole selection; pick a drawing tool to annotate. This replaces the separate "Move Selection" button, and holding `Space` still moves the selection.
- **Shortcuts settings** — the hotkey fields are as wide as the Undo / Redo fields, so both sections line up.
- **Simpler internals, no behavior change** — dead code left over from removed features (launch-time tmp cleanup, old settings migrations, upload progress UI) was deleted; save failures still show the same toast.

## [1.3.0] - 2026-09-26

Fewer options, more fixed defaults.

### Changed

- **OCR & QR always shows the results window and copies the text** — the "OCR & QR Capture" action option was removed.
- **OCR window layout** — the character/word count moved to the footer next to Copy, and the recognized text now lines up with the top of the preview image (which is top-aligned).
- **Settings layout** — General and Capture start at the same height as Keyboard Shortcuts, the Capture checkboxes are evenly spaced, and the Filename field has a fixed width instead of stretching across the window.

### Removed

- **Double-click to copy** — double-clicking inside a selection no longer copies the capture, and its setting is gone. During annotation, quick consecutive clicks could trigger it by accident.

## [1.2.0] - 2026-09-26

Sensible defaults instead of settings, and nothing written to disk as a side effect.

### Changed

- **Snapping is always on** — annotation alignment guides, selection edge snapping to image boundaries (hold `Option` to bypass) and the enhanced browser/Electron element snapping no longer have settings.
- **Default save folder is `~/Downloads`** — screenshots save there without asking for a folder first. Choose another folder in Settings at any time.
- **Selection dimming is always on** — the "Disable shadow outside selection" option was removed.
- **Mouse cursor is never captured** — the "Capture mouse cursor in screenshot" option was removed.
- **No diagnostic logs** — the capture timing log, the termination log and all `os_log` tracing were removed; the app writes no log files.
- **Simpler Filename setting** — the Reset button was removed; an empty template falls back to the default.

### Removed

- **Capture Last Area** — the menu item, hotkey slot, `simpleshot://capture-last` command and the stored selection rectangle are gone.
- **OCR "AI Search" button** — recognized text is no longer sent to a web search from the OCR window.

## [1.1.0] - 2026-09-25

Documentation and polish for SimpleShot.

### Changed

- **Docs rewritten** — README, PRIVACY, SECURITY, CONTRIBUTING and AGENTS now describe SimpleShot; the upstream macshot history moved out of this changelog.
- **Permissions guide** — the Screen Recording screenshot shows the SimpleShot name and icon.

## [1.0.0] - 2026-09-25

First SimpleShot release: a minimal, fully local macOS screenshot and annotation tool.

### Changed

- **Renamed to SimpleShot** — new name, bundle id (`com.zkmn73.simpleshot`), logo and app icon, and URL scheme (`simpleshot://`).
- **Single build** — the separate "Offline" variant is gone; there is one app.
- **Fixed toolbar theme** — the toolbar always uses the default theme; accent, icon and background colors are no longer configurable.
- **English only** — all other localizations were removed.
- **Toolbar and settings simplified** — every annotation tool and the OCR / Scroll Capture actions are always available; the Tools settings tab, menu bar order and menu bar icon customization, single-key tool shortcuts, and the settings footer were removed.
- **Distribution through Homebrew** — `brew install --cask zkmn73/tap/simpleshot`. Releases are built by GitHub Actions and published as `SimpleShot.dmg`.

### Removed

- **Sparkle auto-update** — including the "Check for Updates" menu item, the update settings, and the beta channel. Use `brew upgrade --cask simpleshot`.
- **All network access** — cloud upload (imgbb, Google Drive, S3) and translation are gone, and the app no longer requests the network entitlement.
- **Screen recording** — MP4/GIF recording and the whole video editor.
- **Screenshot history**, the floating thumbnail, and the capture sound.
- **Pin to screen**, including pin from clipboard.
- **Beautify**, image effects (Adjust), Invert Colors, Remove Background, Share, and the Stamp / Emoji tool.
- **Auto-redact toolbar entry** — automatic PII, face and people redaction is still available from the Censor tool's options.

### Kept

- Region, full-screen, last-area, quick and OCR & QR capture with window snap, boundary snap, resolution presets and multi-monitor support.
- Scroll capture.
- Annotation tools: Pencil, Line, Arrow, Rectangle, Ellipse, Marker, Text, Number, Censor (pixelate, blur, solid, erase), Highlight, Loupe, Color Picker and Measure.
- Copy and save (PNG, JPEG, HEIC, WebP) and the standalone editor window with crop, flip, Add Capture and paste.
- Settings export/import and the `simpleshot://` URL scheme.

### Known limitations

- Builds are ad-hoc signed and not notarized. Homebrew removes the quarantine flag on install, and Screen Recording permission has to be granted again after each upgrade.
