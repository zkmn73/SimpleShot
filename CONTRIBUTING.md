# Contributing to SimpleShot

Thanks for your interest in contributing! SimpleShot is a deliberately minimal fork of [macshot](https://github.com/sw33tLie/macshot): region capture, basic annotation, copy/save, and nothing that needs a network. Bug fixes and polish are welcome; the bar for new features is high.

## Before you start

- **Bug fixes:** Open a PR directly with a clear description of what's broken and how you fixed it.
- **New features / large changes:** Open an issue first to discuss the approach. Anything that adds a network dependency, an account, a background service or a large new subsystem is unlikely to fit; removing complexity is always welcome.
- **Small improvements** (UI polish, performance, code cleanup): PRs welcome without prior discussion.

## Development setup

1. Open `macshot.xcodeproj` in Xcode (the project, scheme and source folder keep the upstream `macshot` name; the app itself is SimpleShot)
2. Build & Run (Cmd+R). To keep the Screen Recording permission across rebuilds, build with `DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic`
3. Grant Screen Recording permission when prompted

The project uses synchronized file groups — just create `.swift` files in `macshot/` and Xcode picks them up.

## Tests

```
scripts/run-tests.sh                      # everything
scripts/run-tests.sh AnnotationGeometryTests          # one class
scripts/run-tests.sh AnnotationGeometryTests/testMoveIsReversible   # one test
```

The `macshotTests` target compiles the app sources directly instead of using a
host app, so tests run headless — no Screen Recording permission, no windows.
Add `.swift` files to `macshotTests/` and Xcode picks them up.

What belongs in a test: anything that is a function of its inputs — coordinate
maths, hit testing, encoding and decoding, filename templates, shortcut
matching, the pixel comparisons behind scroll capture. AppKit types are fine
(`NSImage`, `NSEvent`, `NSColor` all work headless); building fixtures with
`ImageProbe.makeImage` keeps pixels identical on Retina and in CI.

What doesn't: anything needing real screen capture, a window server session, or
the network. Where that logic matters, extract the computation — see
`ScrollFrameAnalyzer` (pixel maths split out of the capture session).

`macshotTests/TestSupport.swift` has the shared helpers: `withDefaults` for
isolated UserDefaults, `ImageProbe` for deterministic images and pixel probes,
`TestKeyEvent` for synthesized key events, and `Reflect`/`FieldDescriber` for
comparing every stored property of a value at once.

## Guidelines

- **Pure AppKit.** No SwiftUI, no Electron, no web views.
- **No new dependencies** unless absolutely necessary. Prefer Apple frameworks (the only package today is Swift-WebP).
- **No network access.** The app ships without the network entitlement; keep it that way.
- **Minimum target is macOS 12.3.** Use `@available` guards for newer APIs.
- **Test on single and multi-monitor setups** if your change touches coordinates, overlays, or screen capture.
- **Don't add features to the PR beyond what it claims to fix/add.** Keep PRs focused.
- **Match existing code style.** No SwiftLint, no formatter — just follow what's already there.

## PR checklist

- [ ] Builds without warnings (also check `xcodebuild -scheme macshot -configuration Release build`; Release enforces strict concurrency)
- [ ] `scripts/run-tests.sh` passes, with tests for any logic you added
- [ ] Tested manually in the real app
- [ ] Doesn't break existing behavior
- [ ] Commit message describes *what* and *why*

## Questions?

Open an issue or start a discussion.
