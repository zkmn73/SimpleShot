import Cocoa
import ScreenCaptureKit

struct ScreenCapture {
    let screen: NSScreen
    let image: CGImage
}

class ScreenCaptureManager {

    struct ImmediateCaptureContext {
        let screens: [NSScreen]
        let mainHeight: CGFloat
    }

    // MARK: - SCShareableContent cache

    /// Cached shareable content to avoid repeated (slow) enumeration.
    private static var cachedContent: SCShareableContent?
    private static var cachedContentTime: Date = .distantPast
    /// Cache is valid for 2 seconds — long enough to survive the hotkey→capture gap,
    /// short enough that display changes are picked up.
    private static let cacheTTL: TimeInterval = 2.0

    /// Fetch shareable content, using a short-lived cache to avoid redundant enumeration.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, Date().timeIntervalSince(cachedContentTime) < cacheTTL {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        cachedContent = content
        cachedContentTime = Date()
        return content
    }

    /// Pre-warm the shareable content cache so the next capture is instant.
    /// Call this when the menu bar opens or a hotkey is pressed — before the actual capture starts.
    static func prewarm() {
        Task {
            _ = try? await shareableContent()
        }
    }

    /// Synchronous WindowServer snapshot used by global hotkeys before macshot
    /// activates. This preserves transient UI such as menu extras, app menus,
    /// Raycast/Spotlight-style panels, and other windows that disappear as soon
    /// as focus changes.
    static func makeImmediateCaptureContext() -> ImmediateCaptureContext {
        let screens = NSScreen.screens
        let mainHeight = screens.first?.frame.height ?? 0

        return ImmediateCaptureContext(
            screens: screens,
            mainHeight: mainHeight)
    }

    static func captureAllScreensImmediately(
        context: ImmediateCaptureContext
    ) -> [ScreenCapture] {
        return context.screens.enumerated().compactMap { index, screen in
            let cgRect = CGRect(
                x: screen.frame.origin.x,
                y: context.mainHeight - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height)
            guard
                let image = CGWindowListCreateImage(
                    cgRect, .optionAll, kCGNullWindowID, .bestResolution
                )
            else {
                return nil
            }
            return ScreenCapture(screen: screen, image: image)
        }
    }

    /// SCScreenshotManager-based immediate capture (macOS 14+). Unlike
    /// `captureAllScreensImmediately` (which uses CGWindowListCreateImage and
    /// cannot exclude the WindowServer-composited cursor — notably the enlarged
    /// shake-to-find / accessibility pointer), SCK never paints the cursor when
    /// `showsCursor` is false, so screenshots never contain the cursor.
    ///
    /// On macOS 26+, first uses the rect-based screenshot API. That avoids
    /// enumerating SCShareableContent in the hot path, while still freezing
    /// trigger-time pixels before the overlay is ordered front. If that fails,
    /// falls back to the older content-filter path, which fetches fresh
    /// shareable content so transient UI present at hotkey time — open menus,
    /// Spotlight/Raycast panels — is in the window list and gets captured.
    /// Returns nil on any failure so the caller can fall back to the synchronous
    /// CGWindowListCreateImage path.
    @available(macOS 14.0, *)
    static func captureAllScreensImmediatelySCK() async -> [ScreenCapture]? {
        if #available(macOS 26.0, *) {
            if let captures = await captureAllScreensImmediatelySCKRect() {
                return captures
            }
        }

        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        else {
            return nil
        }

        let screens = NSScreen.screens
        var pairs: [(SCDisplay, NSScreen)] = []
        for display in content.displays {
            if let screen = screens.first(where: { nsScreen in
                let screenNumber =
                    nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID
                return screenNumber == display.displayID
            }) {
                pairs.append((display, screen))
            }
        }
        guard !pairs.isEmpty else {
            return nil
        }

        let captures = await withTaskGroup(
            of: ScreenCapture?.self, returning: [ScreenCapture].self
        ) { group in
            for pair in pairs {
                let (display, screen) = pair
                group.addTask {
                    // Capture the whole display, excluding nothing: transient UI
                    // must be preserved. The cursor is never captured
                    // (showsCursor is false).
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    let scale = Int(screen.backingScaleFactor)
                    config.width = display.width * scale
                    config.height = display.height * scale
                    config.showsCursor = false
                    config.captureResolution = .best
                    guard
                        let image = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: config)
                    else {
                        return nil
                    }
                    return ScreenCapture(screen: screen, image: image)
                }
            }
            var results: [ScreenCapture] = []
            for await capture in group { if let capture = capture { results.append(capture) } }
            return results
        }

        // If SCK couldn't produce an image for every display, fall back rather
        // than show a partial capture.
        guard captures.count == pairs.count else {
            return nil
        }
        return captures
    }

    @available(macOS 26.0, *)
    private static func captureAllScreensImmediatelySCKRect() async -> [ScreenCapture]? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return nil
        }

        // SCScreenshotManager.captureScreenshot(rect:) takes CoreGraphics display
        // space: origin at the TOP-left of the primary display, y down. NSScreen
        // frames are AppKit space: origin at the BOTTOM-left of the primary, y up.
        // The two only coincide for the primary display — non-primary screens
        // captured with the raw AppKit frame come back vertically shifted with a
        // black stripe where the rect fell off the display (#291, #294).
        guard let primaryScreen = screens.first else { return [] }
        let primaryHeight = primaryScreen.frame.maxY
        let captures = await withTaskGroup(
            of: ScreenCapture?.self,
            returning: [ScreenCapture].self
        ) { group in
            for screen in screens {
                group.addTask {
                    let appKitFrame = screen.frame
                    let rect = CGRect(
                        x: appKitFrame.origin.x,
                        y: primaryHeight - appKitFrame.maxY,
                        width: appKitFrame.width,
                        height: appKitFrame.height)
                    let config = SCScreenshotConfiguration()
                    config.width = Int(rect.width * screen.backingScaleFactor)
                    config.height = Int(rect.height * screen.backingScaleFactor)
                    config.showsCursor = false
                    // Rectangle screenshots omit window framing by default on
                    // macOS 26. Preserve the shadows visible on the desktop.
                    config.ignoreShadows = false
                    config.displayIntent = .local
                    config.dynamicRange = .sdr
                    let result = await captureScreenshotOutput(rect: rect, configuration: config)
                    guard
                        result.error == nil,
                        let output = result.output,
                        let image = output.sdrImage ?? output.hdrImage
                    else {
                        return nil
                    }
                    return ScreenCapture(screen: screen, image: image)
                }
            }

            var results: [ScreenCapture] = []
            for await capture in group {
                if let capture { results.append(capture) }
            }
            return results
        }

        guard captures.count == screens.count else {
            return nil
        }

        return captures
    }

    @available(macOS 26.0, *)
    private static func captureScreenshotOutput(
        rect: CGRect,
        configuration: SCScreenshotConfiguration
    ) async -> (output: SCScreenshotOutput?, error: Error?) {
        await withCheckedContinuation { continuation in
            SCScreenshotManager.captureScreenshot(rect: rect, configuration: configuration) {
                output,
                error in
                continuation.resume(returning: (output, error))
            }
        }
    }

    static func makeDisplayPreviewImage(from image: CGImage, maxPixelDimension: Int = 1400) -> CGImage {
        let maxDimension = max(image.width, image.height)
        guard maxDimension > maxPixelDimension else { return image }

        let scale = CGFloat(maxPixelDimension) / CGFloat(maxDimension)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func captureAllScreens(
        excludingWindowNumbers: [CGWindowID] = [],
        completion: @escaping ([ScreenCapture]) -> Void
    ) {
        Task {
            do {
                // When excluding windows, fetch fresh content so newly-created
                // windows (e.g. thumbnails spawned after the cache was built) are
                // present in the window list and can actually be excluded.
                let content: SCShareableContent
                if !excludingWindowNumbers.isEmpty {
                    content = try await SCShareableContent.excludingDesktopWindows(
                        true, onScreenWindowsOnly: true)
                } else {
                    content = try await shareableContent()
                }
                let displays = content.displays
                let screens = NSScreen.screens

                // Resolve window numbers to SCWindow objects for exclusion
                let excludedSCWindows: [SCWindow] = excludingWindowNumbers.compactMap { wid in
                    content.windows.first(where: { CGWindowID($0.windowID) == wid })
                }

                // Build display-screen pairs
                var pairs: [(SCDisplay, NSScreen)] = []
                for display in displays {
                    if let screen = screens.first(where: { nsScreen in
                        let screenNumber =
                            nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                        return screenNumber == display.displayID
                    }) {
                        pairs.append((display, screen))
                    }
                }

                // Capture all displays concurrently
                let captures = await withTaskGroup(
                    of: ScreenCapture?.self, returning: [ScreenCapture].self
                ) { group in
                    for pair in pairs {
                        let (display, screen) = pair
                        group.addTask {
                            if #available(macOS 14.0, *) {
                                // SCScreenshotManager: single-shot API, no stream overhead
                                let filter = SCContentFilter(
                                    display: display, excludingWindows: excludedSCWindows)
                                let config = SCStreamConfiguration()
                                let scale = Int(screen.backingScaleFactor)
                                config.width = display.width * scale
                                config.height = display.height * scale
                                config.showsCursor = false
                                config.captureResolution = .best

                                guard
                                    let image = try? await SCScreenshotManager.captureImage(
                                        contentFilter: filter, configuration: config
                                    )
                                else {
                                    return nil
                                }
                                return ScreenCapture(screen: screen, image: image)
                            } else {
                                // macOS 12.3–13.x: use CGWindowListCreateImage which returns
                                // a CGImage directly — no pixel buffer format ambiguity.
                                // Convert the AppKit screen frame (bottom-left origin) to the
                                // CGDisplay coordinate space (top-left origin) for the capture rect.
                                let mainHeight =
                                    NSScreen.screens.first?.frame.height ?? screen.frame.height
                                let cgRect = CGRect(
                                    x: screen.frame.origin.x,
                                    y: mainHeight - screen.frame.origin.y - screen.frame.height,
                                    width: screen.frame.width,
                                    height: screen.frame.height)
                                guard
                                    let image = CGWindowListCreateImage(
                                        cgRect, .optionAll, kCGNullWindowID, .bestResolution
                                    )
                                else {
                                    return nil
                                }
                                return ScreenCapture(screen: screen, image: image)
                            }
                        }
                    }
                    var results: [ScreenCapture] = []
                    for await capture in group {
                        if let capture = capture {
                            results.append(capture)
                        }
                    }
                    return results
                }

                await MainActor.run { completion(captures) }
            } catch {
                #if DEBUG
                    NSLog("macshot: screen capture error: \(error.localizedDescription)")
                #endif
                await MainActor.run { completion([]) }
            }
        }
    }

    // MARK: - Single window capture (with transparency)

    /// Captures a single window by its CGWindowID, returning an image with transparent corners.
    /// On macOS 14+, uses `desktopIndependentWindow` filter for clean transparent background.
    /// On macOS 12–13, uses `CGWindowListCreateImage` targeting the specific window.
    static func captureWindow(windowID: CGWindowID, screen: NSScreen) async -> CGImage? {
        func captureViaWindowList() -> CGImage? {
            CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .bestResolution)
        }

        if #available(macOS 14.0, *) {
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
            else { return captureViaWindowList() }
            guard
                let scWindow = content.windows.first(where: { CGWindowID($0.windowID) == windowID })
            else { return captureViaWindowList() }

            let filter: SCContentFilter
            if #available(macOS 14.2, *) {
                filter = SCContentFilter(desktopIndependentWindow: scWindow)
            } else {
                guard
                    let display = content.displays.first(where: {
                        let screenID =
                            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                        return screenID != nil && $0.displayID == screenID!
                    }) ?? content.displays.first
                else { return captureViaWindowList() }
                let otherWindows = content.windows.filter { CGWindowID($0.windowID) != windowID }
                filter = SCContentFilter(display: display, excludingWindows: otherWindows)
            }

            let config = SCStreamConfiguration()
            let scale = Int(screen.backingScaleFactor)
            config.width = Int(scWindow.frame.width) * scale
            config.height = Int(scWindow.frame.height) * scale
            config.showsCursor = false
            config.captureResolution = .best

            guard
                let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
            else { return captureViaWindowList() }
            return image
        } else {
            // macOS 12.3–13.x: CGWindowListCreateImage targeting the specific window
            return captureViaWindowList()
        }
    }
}
