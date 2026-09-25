# SimpleShot

Native macOS screenshot & annotation tool. Swift + AppKit, no Qt, no Electron. SimpleShot is a deliberately minimal fork of [macshot](https://github.com/sw33tLie/macshot); the internal names (`macshot/` source folder, `macshot.xcodeproj`, scheme `macshot`, `macshotTests/`, Swift type names) still carry the upstream name on purpose. The product, bundle id and everything user-visible say SimpleShot.

## Project Direction

**Keep it minimal.** Region / full-screen capture, basic annotation, copy / save, and nothing that needs a network. When in doubt, remove rather than add.

- No network access (the app has no network entitlement), no accounts, no in-app updater (updates go through Homebrew), no telemetry, no log files.
- Prefer fixed, sensible defaults over new settings. A new setting or customization needs a strong reason.
- English only. There is a single `en.lproj/Localizable.strings`.
- One build, no variants. Use `AppInfo.displayName` for the display name.

**Removed on purpose — do not reintroduce unless asked:** cloud upload (imgbb / Google Drive / S3), screenshot history, screen recording and the video editor, Pin to screen, Beautify / image effects / Invert Colors / Remove Background, Share, translation, Sparkle auto-update and the beta channel, multi-language localization, the floating thumbnail, capture sound, single-key tool shortcuts, toolbar theme and menu bar customization, the Tools settings tab, Capture Last Area, mouse cursor capture, OCR "AI Search", diagnostic logs, the Offline build variant, and the toggles for snap guides / boundary snap / browser element snap / selection dimming.

**Kept as inert internals:** `AnnotationTool` has implicit raw values, so cases are never deleted. `translateOverlay` is retired but still decodes; `stamp` is only created by the editor's Add Capture; `select`, `crop` and `blur` are not toolbar tools. Never reorder or remove cases.

## Project Setup

- **Language:** Swift 5.0
- **UI:** AppKit, all windows created in code (the storyboard is just the app entry + main menu)
- **Min target:** macOS 12.3 (Monterey)
- **Bundle ID:** `com.zkmn73.simpleshot` (tests: `com.zkmn73.simpleshotTests`)
- **Sandbox:** enabled. Entitlements: `files.user-selected.read-write`, `files.bookmarks.app-scope`, `files.downloads.read-write`, plus a `mach-lookup` exception for `com.apple.axserver` (Accessibility from the sandbox). No network.
- **LSUIElement:** YES (menu bar app, no Dock icon; switches to `.regular` while editor windows are open)
- **Permissions:** Screen Recording (required); Accessibility (optional, for scroll capture and element snapping)
- **Dependencies:** Swift-WebP (WebP encoding). Everything else is Apple frameworks: ScreenCaptureKit, Vision, CoreImage.
- **Xcode:** file-system-synchronized groups. Just create `.swift` files in `macshot/` and Xcode picks them up.
- **App icon:** Icon Composer bundle `macshot/AppIcon.icon` (a legacy `.appiconset` makes macOS 26 draw a gray plate behind the icon). Menu bar icon: `Assets.xcassets/StatusBarIcon` (template image). Logo: `assets/logo.svg`.

## Build & Distribution

One app: product `SimpleShot`, release asset `SimpleShot.dmg`. Users install and update through the Homebrew cask in the personal tap:

```bash
brew trust zkmn73/tap
brew install --cask zkmn73/tap/simpleshot
```

Releases are ad-hoc signed and not notarized unless the Developer ID secrets are configured (see Releasing).

## Architecture

Menu bar agent app. No main window. A global hotkey (default `Cmd+Shift+X`) or the menu bar triggers screen capture → fullscreen overlay → selection → annotation → output (copy / save / OCR / editor).

### File Structure

```
macshot/
├── main.swift                          # App entry point
├── AppDelegate.swift                   # Lifecycle, status bar menu, hotkeys, URL scheme, capture orchestration
├── AppIcon.icon/                       # Icon Composer app icon
│
├── Model/
│   ├── Annotation.swift                # Annotation class + AnnotationTool enum; each annotation draws itself
│   ├── AnnotationCodable.swift         # CodableAnnotation: (de)serialization of annotations
│   ├── LenientDecoding.swift           # Backward/forward-compatible Codable helpers
│   └── SavedCaptureValidation.swift    # Bounds/limits applied when decoding saved annotation data
│
├── Capture/
│   ├── ScreenCaptureManager.swift      # Multi-screen capture via ScreenCaptureKit (+ CGWindowList fallback)
│   ├── ScrollCaptureController.swift   # Scroll capture with SAD-based stitching
│   ├── ScrollFrameAnalyzer.swift       # Pure pixel comparison: frozen header + scrollbar detection
│   └── SafeNumerics.swift              # NaN/inf-safe numeric conversions
│
├── Services/
│   ├── ImageEncoder.swift              # PNG/JPEG/HEIC/WebP encoding, clipboard copy, Retina downscale
│   ├── ImageSaveService.swift          # Save-to-folder / save panel flows, failure reporting
│   ├── SaveDirectoryAccess.swift       # Default ~/Downloads + security-scoped bookmark for a chosen folder
│   ├── FilenameFormatter.swift         # Filename templates ({date}, {window}, {random}, …)
│   ├── FilenameSanitizer.swift         # Single-component, length-capped filenames
│   ├── AtomicMediaSave.swift           # Atomic publish of saved files (stage on destination volume, rename)
│   ├── MediaExportCoordinator.swift    # Tracks in-flight saves so Quit waits for them
│   ├── ApplicationTerminationCoordinator.swift  # Drains pending work, then retries Quit
│   ├── HotkeyManager.swift             # Global hotkeys (Carbon RegisterEventHotKey)
│   ├── KeyboardShortcutMatcher.swift   # Layout-aware character matching for shortcuts
│   ├── EditorCommandShortcutManager.swift  # Configurable undo/redo chords
│   ├── VisionOCR.swift                 # Vision text/QR recognition request factory
│   ├── AutoRedactor.swift              # PII regex detection + Vision → redaction annotations (Censor tool)
│   ├── PIIRedactionPlanner.swift       # Pure planning of what to redact
│   ├── BoundarySnapIndex.swift         # Image-edge index for selection boundary snapping
│   ├── DeferredRestoration.swift       # Hidden-window bookkeeping across overlapping capture cycles
│   ├── ScreenFallback.swift            # NSScreen.preferred: safe screen lookup when macOS reports no display
│   ├── SettingsPortability.swift       # Settings export/import + the secret filter
│   ├── LaunchCleanup.swift             # Sweeps stale tmp files at launch
│   ├── TmpScratchDirectory.swift       # Short-lived tmp files for drag/share
│   ├── AppInfo.swift                   # AppInfo.displayName
│   └── Localization.swift              # English-only L("…") lookup
│
├── UI/
│   ├── Overlay/
│   │   ├── OverlayView.swift           # Base canvas: selection, drawing, annotation rendering, input routing
│   │   ├── OverlayView+Popovers.swift  # Popover factories
│   │   ├── OverlayView+WindowSnapping.swift  # Window/element detection + snap highlight (Tab cycles modes)
│   │   ├── OverlayWindowController.swift     # One per screen: pooled fullscreen borderless overlay window
│   │   ├── ResolutionBoxView.swift / ResolutionPresets.swift  # Selection size box + aspect/pixel presets
│   │   ├── ScrollCaptureHUDView.swift / ScrollCapturePreviewPanel.swift  # Scroll capture HUD + live preview
│   │   └── ColorWheelRenderer.swift    # Radial color wheel for right-click quick color pick
│   ├── Editor/
│   │   ├── EditorView.swift            # OverlayView subclass: NSScrollView mode, no selection chrome
│   │   ├── DetachedEditorWindowController.swift  # Standalone editor window (resizable, titled)
│   │   ├── EditorTopBarView.swift      # Crop, flip, Add Capture, zoom buttons
│   │   └── CenteringClipView.swift     # Centers the document when smaller than the clip view
│   ├── Toolbar/
│   │   ├── ToolbarDefinitions.swift    # ToolbarButtonAction, ToolbarButton, ToolbarLayout (fixed theme colors)
│   │   ├── ToolbarButtonView.swift     # One toolbar button (hover, press, selection states)
│   │   ├── ToolbarStripView.swift      # Horizontal/vertical button strip
│   │   └── ToolOptionsRowView.swift    # Tool options bar (sliders, segments, text formatting)
│   ├── Tools/
│   │   ├── AnnotationToolHandler.swift # AnnotationToolHandler + AnnotationCanvas protocols, shared helpers
│   │   ├── *ToolHandler.swift          # Pencil, Marker, Line, Arrow, Rectangle, FilledRectangle, Ellipse,
│   │   │                               # Pixelate (Censor), Loupe, Measure, Number, Highlight, Stamp
│   │   ├── TextEditingController.swift # Text tool: NSTextView lifecycle, formatting, commit, cancel
│   │   ├── OutlineTextRenderer.swift   # Outlined text attributes/layout manager
│   │   └── ScopedUndoTextView.swift    # NSTextView with view-owned undo history
│   ├── Popover/                        # PopoverHelper, ColorPickerView, ListPickerView, FontPickerView,
│   │                                   # ResolutionPresetsView, EmojiPickerView (stamp only)
│   └── Windows/
│       ├── SettingsWindowController.swift     # Settings: General, Capture, Shortcuts, About
│       ├── OCRResultController.swift          # OCR text + QR code results window
│       ├── PermissionOnboardingController.swift  # First-run Screen Recording guide
│       ├── UploadToastController.swift        # Generic toast (name is legacy; used for failure toasts)
│       └── CountdownView.swift                # Delay-capture countdown
│
├── Info.plist, macshot.entitlements
├── Assets.xcassets/                    # StatusBarIcon, Logo, PermissionsGuide, AccentColor
├── en.lproj/Localizable.strings        # The only strings table
└── Base.lproj/Main.storyboard
```

### Component Overview

#### AppDelegate — Entry Point & Orchestrator
- `NSStatusItem` menu: Capture Area, Capture Screen, Capture OCR & QR, Quick Capture, Scroll Capture, Capture Delay, Open Image…, Open from Clipboard, Settings…, Quit.
- Registers global hotkeys via `HotkeyManager`. Defaults: `Cmd+Shift+X` area, `Cmd+Shift+F` full screen, `Cmd+Shift+S` quick capture, `Cmd+Shift+T` OCR & QR. Scroll capture and Open from Clipboard have no default.
- Handles the `simpleshot://` URL scheme (`capture`, `capture-fullscreen`, `quick-capture`, `ocr`, `scroll-capture`, `settings`, `open?file=`).
- On trigger: `ScreenCaptureManager` captures all screens → one `OverlayWindowController` per screen (pooled and pre-warmed).
- Implements `OverlayWindowControllerDelegate`: confirm, cancel, OCR, scroll capture, cross-screen selection sync.
- Manages `overlayControllers[]`, `ocrController`, `scrollCaptureController`.
- "Quick Capture" confirms as soon as the selection is made, then copies and/or saves according to the "Enter / Quick Capture" setting.

#### OverlayView — The Main Interaction Surface
The core canvas view: selection state machine, annotation rendering, input routing, toolbar positioning. Tool creation/update/finish logic lives in `AnnotationToolHandler`s in `UI/Tools/`.

**State machine:** `idle` → `selecting` → `selected`

**Snapping:** window / element / off modes (`Tab` cycles, persisted as `captureSnapMode`); boundary snap of selection edges (hold `Option` to bypass); annotation alignment guides. The three latter are always on.

**Zoom:** 0.1x–8x (min 1.0x in the overlay, 0.1x in the editor), scroll/pinch, pan while zoomed.

**Toolbars:** real NSView strips (`ToolbarStripView` + `ToolbarButtonView`) positioned by `OverlayView`. Bottom toolbar: 13 tools, color, undo/redo. Right toolbar: Cancel, Move Selection, Open in Editor Window, Copy, Save, OCR, Scroll Capture. Tool options in `ToolOptionsRowView`. Popovers use `NSPopover` via `PopoverHelper`.

**Editor mode (`EditorView` subclass):** overrides behavior through clean override points and uses `NSScrollView` for zoom/pan/centering. Use the `isEditorMode` computed property.

**CRITICAL — Overlay vs Editor coordinate rules:**
- **Never use `bounds` for image-to-pixel mapping.** Always use `captureDrawRect` (`bounds` in the overlay, `selectionRect` in the editor).
- **Never use raw view-space points for annotation positions.** Convert via `viewToCanvas()` first.
- **Never call `viewToCanvas()` on a point that's already in canvas space.** `startAnnotation(at:)` receives canvas-space points.
- **When positioning NSViews (e.g. the text tool's NSTextView),** convert canvas coordinates back with `canvasToView()`.
- **`compositedImage()`** renders at `captureDrawRect.size`, not `bounds.size`.
- **`sourceImageBounds`** for pixelate/blur/loupe must be `captureDrawRect`, not `bounds`.
- **For Vision region crops** (OCR, barcode, auto-redact), draw the screenshot at `captureDrawRect` size.
- **Cursor management** is fully imperative (`updateCursorForPoint()` + `mouseMoved`, no cursor rects). Each window only sets cursors when the mouse is actually over it, which prevents cross-window flicker on multi-monitor.

**Drawing pipeline in `draw(_:)`:**
1. Background: screenshot (full-screen in the overlay, centered in the editor via NSScrollView)
2. Dark overlay mask outside the selection (always drawn; skipped in the editor)
3. Selection rectangle with 8 resize handles (skipped in the editor)
4. Annotations, using a cached composite when not actively drawing
5. Snap guides
6. Toolbars positioned (real NSView subviews, not drawn inline)
7. Zoom label (fades out) and scroll capture HUD

#### Tool Handler Architecture
Each annotation tool's creation logic (start/update/finish) is an `AnnotationToolHandler`. `OverlayView` dispatches through `toolHandlers[currentTool]` in `startAnnotation`, `updateAnnotation`, `finishAnnotation`.

- **`AnnotationCanvas`** — the interface handlers use to reach `OverlayView` state (colors, stroke width, annotations, undo stack, snap guides…) without coupling to the whole class.
- **`TextEditingCanvas`** — extra interface for `TextEditingController` (coordinate transforms, commit).
- Not extracted (handled in `OverlayView`): `select` (annotation interaction), `colorSampler`, `crop` (editor-only), and text start/click detection.

#### Annotation — Data Model + Drawing
A class (not a struct) with `clone()` for safe copying, in `Model/Annotation.swift`. Each annotation draws itself via `draw(in:)` and has `hitTest(point:threshold:)`, `move(dx:dy:)`, `isMovable`, `boundingRect`, `drawSelectionHighlight()`.

`AnnotationTool` cases, in declaration order (never reorder): `pencil, line, arrow, rectangle, filledRectangle, ellipse, marker, text, number, pixelate, blur, measure, loupe, select, translateOverlay, crop, colorSampler, stamp, highlight`.

Toolbar tools (13): Pencil, Line, Arrow, Rectangle, Ellipse, Marker, Text, Number, Censor (`pixelate` + `CensorMode`: pixelate / blur / solid / erase, plus auto-redact), Highlight (spotlight), Loupe, Color Picker, Measure.

#### DetachedEditorWindowController — Standalone Editor
- Opens from the overlay's "Open in Editor Window" button, Quick Capture with "Also open in Editor", the menu's Open Image… / Open from Clipboard, or `simpleshot://open`.
- Builds `NSScrollView` → `CenteringClipView` → `EditorView` (documentView); a container view holds the scroll view and `EditorTopBarView` (crop, flip, Add Capture, zoom).
- `chromeParentView` is set BEFORE `applySelection` so toolbars go in the container, not the document view.
- Static `activeControllers[]` keeps instances alive; the activation policy is `.regular` while any are open and `.accessory` once all are closed.

### Protocols

```
OverlayWindowControllerDelegate  — OverlayWindowController → AppDelegate
OverlayViewDelegate              — OverlayView → OverlayWindowController / DetachedEditorWindowController
AnnotationToolHandler            — Tool creation/update/finish lifecycle
AnnotationCanvas                 — OverlayView state interface for tool handlers
TextEditingCanvas                — Coordinate transforms + annotation storage for TextEditingController
LaunchCleaner                    — One sweep rule in LaunchCleanup
```

### Undo/Redo

`UndoEntry` enum: `.added(Annotation)`, `.deleted(Annotation, Int)`, `.imageTransform(...)`, plus property-change entries. Stacks: `undoStack` / `redoStack`. Batch undo via `groupID` (e.g. auto-redact creates several annotations with one groupID, undone together).

**CRITICAL — transient `NSTextView` undo ownership:** `UndoManager` keeps undo-operation targets unowned. A disposable editable `NSTextView` that obtains the window's shared undo manager through the responder chain can leave `_undoRedoTextOperation:` entries pointing at a deallocated view; the next Cmd+Z may crash in `_NSUndoStack popAndInvoke`. Every editable app-created text view with `allowsUndo = true` must be a `ScopedUndoTextView` (or subclass), never a plain `NSTextView`. Call `discardUndoHistory()` before removing and releasing an editing session. Read-only text views are exempt. Do not move transient text editing back onto a window-level undo manager.

### Coordinate Systems
- **Overlay:** view coordinates = screen frame, bottom-left origin (AppKit).
- **Editor:** `EditorView` inside `NSScrollView` — `isInsideScrollView` makes all transforms identity; `NSScrollView` handles zoom/pan/centering.
- **ScreenCaptureKit / CGWindowList / Accessibility:** top-left origin; convert from AppKit bottom-left.
- **Annotation coordinates:** always relative to the overlay/editor view; shifted when moving between overlay and editor.

### Persistence (UserDefaults)
Only remembered choices are stored, and nothing is written as a side effect of taking a screenshot.
- **Output:** `imageFormat` (png/jpeg/heic/webp), `imageQuality`, `downscaleRetina`, `saveDirectory` + `saveDirectoryBookmark` (only after the user picks a folder; default is `~/Downloads`), `filenameTemplate`, `useWindowTitleInFilename`, `quickCaptureMode`, `quickCaptureOpenEditor`, `closeEditorAfterCopy`, `ocrAction`, `autoCopyOCRText`
- **Capture:** `captureDelaySeconds`, `captureSnapMode`, `hideCaptureInstructions`, `scrollAutoScrollEnabled`, `scrollAutoScrollSpeed`, `scrollFrozenDetection`, `scrollMaxHeight`, resolution preset keys (`keepAspectRatio*`, `resolutionUnitIsPoints`, preselection preset keys)
- **Hotkeys:** per slot key code, modifiers and disabled flag (`HotkeyManager.HotkeySlot`); editor undo/redo chords
- **Annotation styles:** `currentStrokeWidth`, `numberStrokeWidth`, `markerStrokeWidth`, `loupeSize`, `lastUsedColor`, `lastUsedColorOpacity`, `customColors`, line/arrow/rect styles, text formatting, `numberFormat`, `censorMode`, pencil smoothing, highlight dim/dashed keys, outline colors
- **App:** `launchAtLogin`, `hideMenuBarIcon`, `urlSchemeEnabled`, `suppressMoveToApplications`, `enabledRedactTypes`

### Threading Model
- **Capture:** async/await `TaskGroup` for concurrent multi-display capture
- **Scroll capture:** background throttle/settlement timers, serialized capture-and-stitch
- **OCR:** `VNImageRequestHandler` on a background thread, results delivered on main
- **Image encoding/saving:** off the main thread; in-flight saves are registered with `MediaExportCoordinator`
- **UI:** all drawing, state changes and user interaction on the main thread

## Coding Conventions

- **Pure AppKit.** No SwiftUI, no web views. Use proper AppKit components (`NSPopover`, `NSSlider`, `NSSegmentedControl`, `NSScrollView`, `NSTextView`); don't reimplement standard controls with manual `draw()` + hit-testing.
- **Strict concurrency.** CI builds Release with Xcode 26 and `-Owholemodule`, which enforces strict Swift concurrency; **Debug builds don't catch these errors**. Always verify with a Release build: `xcodebuild -scheme macshot -configuration Release DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic build 2>&1 | grep "error:"`. Calling `@MainActor` methods (e.g. on `AppDelegate`) from non-`@MainActor` code needs `MainActor.assumeIsolated { }`.
- **Tool handler pattern.** New annotation tools implement `AnnotationToolHandler` in `UI/Tools/`; don't add switch cases to `OverlayView`.
- **Annotation properties.** When adding a property to `Annotation`, update four places: the declaration, `clone()`, `CodableAnnotation` in `AnnotationCodable.swift` (struct field, `toCodable`, `fromCodable`, and a line in `init(from:)`), and the census in `macshotTests/AnnotationPersistenceTests.swift`. The compiler won't catch a missing field, but the census test will (it reflects over every stored property).
- **Persisted models decode leniently.** Synthesized `init(from:)` requires every non-optional key even when it has a default, so adding a field breaks files written by older builds. Any `Codable` written to disk or UserDefaults needs a hand-written `init(from:)` using `decode(_:or:)` / `decodeOptional(_:)` from `Model/LenientDecoding.swift`.
- **Report failures the user can't otherwise see.** A capture that fails to save must not vanish silently. `ImageSaveService.onFailure` is wired to `AppDelegate.showFailureToast(_:)` at launch; never swallow such a failure into an ignored `false` completion.
- **Filenames are single components.** Rendered templates go through `FilenameSanitizer`. Template expansion is one pass: a window title containing `{date}` stays literal. Preserve complete Unicode characters while capping UTF-8 length.
- **Saves outlive windows.** Image saves publish atomically (`AtomicMediaSave`) and register with `MediaExportCoordinator`; `ApplicationTerminationCoordinator` lets Quit wait for them. Keep heavy I/O off the main thread and preserve the old destination on failure.
- **Keyboard shortcuts.** Character-based commands go through `KeyboardShortcutMatcher`; don't compare raw letter key codes or read `charactersIgnoringModifiers` directly. It follows rearranged Latin layouts (QWERTZ, AZERTY, Dvorak) and falls back through an ASCII-capable layout for non-Latin input sources. Use `EditorCommandShortcutManager` for the configurable undo/redo chords. Raw `event.keyCode` is fine only for layout-independent keys (Escape, Return, Tab, Space, Delete, arrows, function keys). Global Carbon hotkeys are physical key-code bindings; translate them only for display with `KeyboardShortcutMatcher.currentLayoutCharacter(for:)`.
- **No file logging.** Don't add log files or `os_log` tracing. Console-only `print` for genuinely unexpected errors is acceptable.
- Minimal allocations during mouse tracking (reuse paths, avoid per-`mouseMoved` object creation).
- `[weak self]` in closures to avoid retain cycles.
- Tear down overlay windows and images promptly after capture; use `autoreleasepool` for overlay teardown.
- Extension files (`OverlayView+Feature.swift`) for self-contained feature code that touches `OverlayView` state (window snapping, popovers).
- **Light/dark mode.** The toolbar and popovers always use a dark background regardless of system appearance. `ToolOptionsRowView` and `PopoverHelper` force `NSAppearance(named: .darkAqua)`. Never use system-adaptive colors (`.labelColor`, `.secondaryLabelColor`) for text in toolbar/popover contexts without verifying contrast. Theme colors come from `ToolbarLayout` and are fixed.
- **Focus management.** SimpleShot is an `LSUIElement` app that temporarily shows windows. All focus return goes through `AppDelegate.returnFocusIfNeeded()`:
  - `previousApp` is captured in `startCapture()` before the overlay steals focus, and cleared after single use.
  - `returnFocusIfNeeded()` checks for visible titled windows, switches to `.accessory`, and activates `previousApp` (or the frontmost non-SimpleShot app if there is none). It deliberately does **not** call `NSApp.hide(nil)`: that hides all windows and can suspend the Carbon event loop, breaking global hotkeys.
  - `dismissOverlays(refocusPreviousApp: true)` (default) calls it. Pass `false` only when SimpleShot creates a floating panel immediately after; then save `previousApp`, dismiss, create the panel, and `activate(options: .activateIgnoringOtherApps)` the saved app.
  - Every window close (editor, OCR window, Settings) calls `returnFocusIfNeeded()`; never inline `setActivationPolicy` / `activate`.
  - All floating panels (overlays, OCR window, toasts, scroll HUD) set `hidesOnDeactivate = false`.
  - `NSApp.activate(options: .activateIgnoringOtherApps)` is the only reliable way to hand focus to another app on macOS 26; plain `activate()` and `NSApp.deactivate()` are not.

## Tests

- `scripts/run-tests.sh` runs everything; pass `ClassName` or `ClassName/testName` to narrow it. It reports failures and keeps the full log/result bundle on failure. Set `MACSHOT_KEEP_TEST_RESULTS=1` to keep successful results too. Empty/all-skipped runs are errors.
- The `macshotTests` target compiles the app sources directly (a synchronized group over `macshot/`, minus `main.swift`), so there is **no host app**: tests run headless, with no Screen Recording permission and no window server. `internal` symbols are reachable without `@testable import`; `private` ones are not.
- Shared helpers live in `macshotTests/TestSupport.swift`: `withDefaults` (isolated UserDefaults), `ImageProbe` (scale-independent fixture images + pixel probes — never build fixtures with `lockFocus`, it yields 2x buffers on Retina and 1x in CI), `TestKeyEvent` (synthesized `NSEvent`s), and `Reflect` / `FieldDescriber` (compare every stored property at once).
- Logic worth testing but buried in a permission-gated class should be extracted rather than left untested — see `ScrollFrameAnalyzer`.
- `LocalizationTests` fails if an `L("…")` key used in code is missing from `en.lproj/Localizable.strings`; add the key whenever you add a new `L("…")`.
- `.github/workflows/tests.yml` runs the suite plus a Release build on every push to `master` and every PR. The Release build is what catches strict-concurrency errors.

## Build & Run

- Open `macshot.xcodeproj` in Xcode and Build & Run (Cmd+R).
- To keep the Screen Recording permission across rebuilds, build with `DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic` (Xcode's stable "Sign to Run Locally" identity).
- The app appears in the menu bar. Click it → "Capture Area", or use the global hotkey (default `Cmd+Shift+X`).

## Releasing

Workflow: `.github/workflows/build-release.yml`. It runs on a tag push (`v*.*.*`) or a manual `workflow_dispatch` with an existing tag. It builds, signs, packages `SimpleShot.dmg`, creates the GitHub Release, and rewrites `Casks/simpleshot.rb` in the tap repo (`TAP_REPO` in the workflow, default `zkmn73/homebrew-tap`).

- **Required secret:** `HOMEBREW_TAP_TOKEN` (PAT with write access to the tap repo).
- **Optional, need a paid Apple Developer account:** `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `ASC_API_KEY`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`. Without the certificate secret the workflow ad-hoc signs, skips notarization, and the cask strips the quarantine flag in a `postflight_steps` block (and warns that Screen Recording must be granted again after each upgrade).

Steps:
1. Add a `## [x.y.z]` entry to `CHANGELOG.md` (used as release notes; if missing, notes are generated from commits).
2. Tag and push: `git tag v1.0.1 && git push origin master --tags`
3. CI does the rest. `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.pbxproj` are only for local builds; CI overrides them from the tag and run number.

Never rapidly create/delete tags — GitHub throttles tag push events. If a tag push doesn't trigger CI, use `gh workflow run build-release.yml --ref master -f tag=v1.0.1`.
