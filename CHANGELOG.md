# Changelog

SimpleShot is a slimmed-down fork of [macshot](https://github.com/sw33tLie/macshot). The upstream history up to 4.3.0-beta.1 is in the [macshot changelog](https://github.com/sw33tLie/macshot/blob/main/CHANGELOG.md).

## [1.5.4] - 2026-10-03

### Changed

- **Simpler internals** — the drawing, editing and option code still kept for the Highlight, Loupe and Measure tools (removed from the toolbar in 1.5.0) is gone, including the unused hold-1/2 auto-measure. About 1,500 lines removed. The only visible effect: annotations of those types copied from SimpleShot 1.4 or earlier are now skipped when pasted; everything else in the paste comes through.
- **No more inert emoji buttons on Add Capture images** — selecting an image added with the editor's Add Capture showed the emoji stamp options (quick emojis, More Emojis, Load Image), which did nothing since there is no stamp tool. That options row and the unused emoji stamp tool behind it are gone; a selected capture still moves and resizes with its handles.

## [1.5.3] - 2026-10-03

### Fixed

- **The editor no longer forgets to ask before discarding a capture** — pressing Enter in an editor opened from a capture marked it as output even when nothing was output (Enter set to "Do nothing") or the save failed, so closing the window discarded the capture without asking.
- **Failures you couldn't see now show a message** — opening an image that can't be read, and a copy to the clipboard that fails, used to do nothing at all.
- **Undoing a crop or Add Capture no longer misplaces annotations** — both operations shift every annotation to follow the image, but undo restored the image without moving the annotations back, leaving them offset from what they were drawn on.
- **Undoing a paste removes only what was pasted** — pasted annotations kept the batch-undo group of the ones they were copied from, so one undo could also remove the originals; pasting several annotations now undoes as one step, like duplicating.
- **Recording a shortcut in Settings works even for a chord that's already in use** — global hotkeys stayed active while recording, so pressing a chord SimpleShot already had (to move it to another action, or to re-record it) started a capture instead of being recorded. They are now paused while recording.
- **Two SimpleShot actions can no longer share a hotkey** — the second one showed the shortcut but never fired. Assigning a chord that another SimpleShot action already has now moves it, and the other action is cleared. (Conflicts with other apps' shortcuts are not detected.)

## [1.5.2] - 2026-10-02

### Removed

- **Censor auto-redact** — the All Text, PII (and its type picker), Faces and People buttons and the "Text Only" draw mode are gone from the Censor tool. Censor is now drawn by hand only, with the same four modes: pixelate, blur, solid fill and smart erase.

### Changed

- **No default global hotkeys** — `Cmd+Shift+X`, `Cmd+Shift+F`, `Cmd+Shift+S` and `Cmd+Shift+T` are no longer assigned out of the box. A global hotkey takes that shortcut away from every other app (`Cmd+Shift+T` is "reopen closed tab" in browsers, `Cmd+Shift+S` is "Save As" almost everywhere). Assign your own in Settings > Shortcuts. **If you were using the defaults, set them again after upgrading**; hotkeys you had changed yourself are kept.
- **The `simpleshot://` URL scheme is now off by default** — any app on your Mac can open these URLs, and `capture-fullscreen-quick` captures and copies/saves the full screen without asking, so another app could use it to get a screenshot without its own Screen Recording permission. If you call SimpleShot from Raycast, Alfred, Shortcuts or a script, turn it back on in Settings > General. A setting you already saved yourself is kept.
- **Settings import/export only touches SimpleShot's own settings** — both directions now use a fixed list of known settings instead of guessing from key names. Importing a file never writes anything else (leftover keys from older builds or upstream macshot, or anything added by hand). Your save folder still stays on this Mac.
- **Simpler internals, no behavior change** — the creation code for the retired Highlight, Loupe and Measure tools was deleted (existing annotations of those types still display and can be moved, resized and deleted), along with an unused entry in `Info.plist`, leftover references to the removed screenshot history, and unused code left over from screen recording and single-key tool shortcuts (save cancellation and progress, file copying, temporary-file leases).

### Fixed

- **Scroll capture on multiple displays** — the overlay used as the "capture what's below this window" reference was picked at random from all displays' overlays, so the overlay on the display being captured could end up in the stitched frames. It now always uses the overlay you started the scroll capture on.
- **Scroll capture hands focus to the scrolled app more reliably** — before auto-scrolling, SimpleShot activated the app under the selection with a call that newer macOS can ignore. It now uses the same cooperative activation as the rest of the app (macOS 14+).
- **AVIF files can be opened** — SimpleShot could save AVIF but refused AVIF files from Finder's "Open With", a drag onto the app icon, or `simpleshot://open?file=`.
- **No empty overlay when a screen can't be captured** — if the fallback capture path got images for only some displays, the others showed an overlay with no screenshot that blocked clicks until Esc. Those displays are now left alone.
- **Out-of-range settings fall back to defaults** — an invalid Enter / Quick Capture action (for example from a hand-edited settings file) is treated as "Copy to clipboard" instead of silently doing nothing, and the capture delay and pencil smoothing are clamped to the values Settings offers.

## [1.5.1] - 2026-09-26

### Added

- **`simpleshot://capture-fullscreen-quick`** — captures the full screen and confirms it with no interaction at all (per your "Enter / Quick Capture" setting), for scripts, Shortcuts and AI agents rather than a person at the keyboard. Every other URL command still needs a human to drag/click a selection and/or confirm it.

## [1.5.0] - 2026-09-26

### Changed

- **Removed Highlight, Loupe and Measure** to simplify the toolbar. Pencil, Line, Arrow, Rectangle, Ellipse, Marker, Text, Number, Censor and Color Picker remain.

### Fixed

- **Delayed capture could get permanently stuck** — if no display was available when the countdown was about to appear (all displays asleep, or a headless session), the app never cleared its "capturing" flag, silently blocking every later capture until relaunch. It now cancels the capture cleanly instead of leaving that flag stuck.
- **Scroll capture's frozen-header detection could lock in a bad guess** — a bug left the second confirming sample unreachable, so a single misjudged frame could permanently crop the wrong amount off the top of every stitched frame for the rest of the capture. The second-sample confirmation now actually runs, and a disagreeing sample properly discards the unconfirmed guess instead of keeping it.

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
