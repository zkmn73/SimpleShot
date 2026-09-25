# Changelog

SimpleShot is a slimmed-down fork of [macshot](https://github.com/sw33tLie/macshot). The upstream history up to 4.3.0-beta.1 is in the [macshot changelog](https://github.com/sw33tLie/macshot/blob/main/CHANGELOG.md).

## [1.0.0] - 2026-09-25

First SimpleShot release: a minimal, fully local macOS screenshot and annotation tool.

### Changed

- **Renamed to SimpleShot** — new name, bundle id (`com.zkmn73.simpleshot`), logo and app icon, and URL scheme (`simpleshot://`).
- **Single build** — the separate "Offline" variant is gone; there is one app.
- **Fixed toolbar theme** — the toolbar always uses the default theme; accent, icon and background colors are no longer configurable.
- **English only** — all other localizations were removed.
- **Snapping is always on** — annotation alignment guides, selection edge snapping to image boundaries (hold `Option` to bypass) and the enhanced browser/Electron element snapping no longer have settings.
- **Default save folder is `~/Downloads`** — screenshots save there without asking for a folder first. Choose another folder in Settings at any time.
- **No diagnostic logs** — the capture timing log, the termination log and all `os_log` tracing were removed; the app writes no log files.
- **OCR "AI Search" button removed** — recognized text is no longer sent to a web search from the OCR window.
- **Mouse cursor is never captured** — the "Capture mouse cursor in screenshot" option was removed.
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
