import Cocoa
import Carbon
import ServiceManagement
import UniformTypeIdentifiers
import AVFoundation
import Vision
import WebP

enum CaptureMenuItemID: String, CaseIterable {
    case captureArea = "captureArea"
    case captureScreen = "captureScreen"
    case captureOCR = "captureOCR"
    case quickCapture = "quickCapture"
    case scrollCapture = "scrollCapture"

    static let defaultOrder: [CaptureMenuItemID] = [
        .captureArea,
        .captureScreen,
        .captureOCR,
        .quickCapture,
        .scrollCapture,
    ]

    var title: String {
        switch self {
        case .captureArea: return L("Capture Area")
        case .captureScreen: return L("Capture Screen")
        case .captureOCR: return L("Capture OCR & QR")
        case .quickCapture: return L("Quick Capture")
        case .scrollCapture: return L("Scroll Capture")
        }
    }

    var symbolName: String {
        switch self {
        case .captureArea: return "crop"
        case .captureScreen: return "desktopcomputer"
        case .captureOCR: return "text.viewfinder"
        case .quickCapture: return "square.and.arrow.down"
        case .scrollCapture: return "scroll"
        }
    }

    var hotkeySlot: HotkeyManager.HotkeySlot {
        switch self {
        case .captureArea: return .captureArea
        case .captureScreen: return .captureFullScreen
        case .captureOCR: return .captureOCR
        case .quickCapture: return .quickCapture
        case .scrollCapture: return .scrollCapture
        }
    }

}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var overlayControllers: [OverlayWindowController] = []
    private var settingsController: SettingsWindowController?
    private var onboardingController: PermissionOnboardingController?
    private var ocrController: OCRResultController?
    private var isCapturing = false
    private var delayCountdownWindow: NSWindow?
    private var delayTimer: Timer?
    private var delayEscMonitor: Any?
    /// Transient toast for failures that would otherwise be invisible — a save
    /// that couldn't be written, a recording that produced no file.
    private var errorToastController: FailureToastController?
    private let terminationCoordinator = ApplicationTerminationCoordinator()
    private var scrollCaptureController: ScrollCaptureController?
    /// The overlay controller whose selection is being scroll-captured.
    private var scrollCaptureOverlayController: OverlayWindowController?
    private var scrollCapturePreviewPanel: ScrollCapturePreviewPanel?
    private var statusBarMenu: NSMenu?
    private var captureSessionID: UInt = 0
    /// Launch Services can deliver file/URL open requests before
    /// `applicationDidFinishLaunching`. Defer them until launch setup and the
    /// initial overlay-pool prewarm have completed; otherwise a cold-launch
    /// capture can be torn down by `rebuildOverlayPool()` later in startup.
    private var isReadyForOpenRequests = false
    private var pendingOpenURLs: [URL] = []
    /// Capture/record URL actions additionally wait for Screen Recording
    /// permission. Non-capture actions (settings, history, file opens, etc.)
    /// remain usable while the onboarding window is shown.
    private var isReadyForScreenCaptureURLs = false
    private var pendingScreenCaptureURLs: [URL] = []
    /// App Nap suppression assertion. Held for the app's lifetime so global
    /// hotkeys respond instantly instead of paying a wake-up penalty when
    /// macshot has been idle. Use the idle-sleep-safe variant: plain
    /// `.userInitiated` creates a `PreventUserIdleSystemSleep` assertion and
    /// keeps Macs awake indefinitely.
    private var appNapAssertion: NSObjectProtocol?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Prevent multiple instances — if already running, activate the existing one and quit
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zkmn73.simpleshot"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            // Tell the existing instance to show its icon and open Settings
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.zkmn73.simpleshot.showAndOpenPrefs"),
                object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        // Surface save failures — otherwise a capture that can't be written
        // (full disk, unmounted volume) disappears without a word.
        ImageSaveService.onFailure = { [weak self] message in
            self?.showFailureToast(message)
        }

        // Disable App Nap. macshot is LSUIElement with no visible windows
        // when idle, so macOS can add wake-up latency to global hotkey
        // captures. The "allowing idle system sleep" variant keeps the
        // responsiveness hint without creating a PreventUserIdleSystemSleep
        // assertion that blocks normal sleep.
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Global hotkey responsiveness")

        // Offer to move to /Applications if running from a DMG or translocated path
        promptToMoveToApplicationsIfNeeded()

        setupMainMenu()
        setupStatusBar()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(keyboardInputSourceDidChange),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            setMenuBarIconVisible(false)
        }
        registerHotkey()

        // Listen for duplicate-launch notification to restore icon
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowAndOpenPrefs),
            name: .init("com.zkmn73.simpleshot.showAndOpenPrefs"), object: nil
        )

        // Dismiss overlays when the user switches spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Check screen recording permission. If not yet granted, show the
        // custom onboarding window instead of letting macOS throw its own dialogs.
        PermissionOnboardingController.checkPermissionSync { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.markScreenCaptureURLsReady()
            } else {
                self.showOnboarding()
            }
        }

        // Replay requests on the next run-loop turn so AppKit has completely
        // finished its launch lifecycle before an action presents UI or starts
        // a capture. Keep accepting requests into the queue until this runs so
        // their delivery order is preserved.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isReadyForOpenRequests = true
            let urls = self.pendingOpenURLs
            self.pendingOpenURLs.removeAll()
            self.handleOpenURLs(urls)
        }
    }

    private func showOnboarding() {
        // If already open, just bring it to front
        if let existing = onboardingController {
            existing.show()
            return
        }
        let oc = PermissionOnboardingController()
        oc.onPermissionGranted = { [weak self] in
            guard let self = self else { return }
            self.onboardingController = nil
            self.markScreenCaptureURLsReady()
        }
        oc.onClose = { [weak self, weak oc] in
            guard let self = self, self.onboardingController === oc else { return }
            self.onboardingController = nil
            // Closing onboarding abandons any action that was waiting for its
            // permission; never surprise the user by replaying it much later.
            self.pendingScreenCaptureURLs.removeAll()
        }
        onboardingController = oc
        oc.show()
    }

    private func prewarmCapturePath() {
        // Warm the SCShareableContent cache (cheap, async).
        ScreenCaptureManager.prewarm()
        // Build (or rebuild) the per-screen overlay controller pool. Each
        // controller owns a permanent NSPanel; on hotkey we reuse it rather
        // than creating fresh. This is what keeps captures fast — WindowServer
        // caches composition state per-window, and reused windows stay hot.
        rebuildOverlayPool()
    }

    private func markScreenCaptureURLsReady() {
        guard !isReadyForScreenCaptureURLs else { return }
        // Do not rebuild underneath a capture started through another entry
        // point. A later capture can create any missing pooled controller on
        // demand.
        if !isCapturing {
            prewarmCapturePath()
        }
        isReadyForScreenCaptureURLs = true
        let urls = pendingScreenCaptureURLs
        pendingScreenCaptureURLs.removeAll()
        handleOpenURLs(urls)
    }

    /// Persistent per-screen overlay controller pool. Held for the app's
    /// lifetime so each panel's CGSWindow stays alive in WindowServer.
    /// Rebuilt on screen-config change.
    private var overlayControllerPool: [ObjectIdentifier: OverlayWindowController] = [:]

    private func rebuildOverlayPool() {
        // Tear down stale controllers (screens removed, etc.) before rebuilding.
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        for screen in NSScreen.screens {
            let controller = OverlayWindowController(screen: screen)
            overlayControllerPool[ObjectIdentifier(screen)] = controller
            // Warm the panel: brief invisible orderFront so WindowServer
            // allocates the surface + composes one frame. This is what the
            // first real capture would otherwise pay.
            controller.warmPanel()
        }
    }

    private func pooledController(for screen: NSScreen) -> OverlayWindowController {
        if let existing = overlayControllerPool[ObjectIdentifier(screen)] {
            return existing
        }
        // New screen showed up between prewarms — create on demand.
        let controller = OverlayWindowController(screen: screen)
        overlayControllerPool[ObjectIdentifier(screen)] = controller
        controller.warmPanel()
        return controller
    }

    @objc private func systemDidWake() {
        guard !isCapturing else { return }
        prewarmCapturePath()
    }

    @objc private func screenParametersDidChange() {
        guard !isCapturing else { return }
        prewarmCapturePath()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-launching macshot while it's running: show the menu bar icon
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        // Only open settings if no windows are visible (e.g. pure menu-bar state).
        // If editor/video editor is already open, just bring the app to the front.
        if !flag {
            openSettings()
        }
        return false
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Dock menu shown on right-click of the Dock icon.
    ///
    /// macOS only auto-populates the Dock menu's window list for document-based
    /// apps (apps using `NSDocumentController`). Our editor windows aren't
    /// documents, so we build the list ourselves: each visible titled window
    /// gets an entry that brings that specific window forward when clicked.
    /// Without this users only see "Show All Windows" and can't jump directly
    /// to a particular editor session.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let windows = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !windows.isEmpty else { return nil }
        let menu = NSMenu()
        // Sort by title so the menu order is stable across dock-menu openings.
        for window in windows.sorted(by: { $0.title < $1.title }) {
            let item = NSMenuItem(
                title: window.title.isEmpty ? L("Untitled") : window.title,
                action: #selector(activateWindowFromDockMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = window
            if window.isMiniaturized {
                // Visual cue so users know clicking will also de-minimize.
                item.state = .mixed
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func activateWindowFromDockMenu(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// If the app is running from a DMG volume or a translocated path,
    /// offer to move it to /Applications for proper operation (auto-updates,
    /// persistent preferences, no translocation issues).
    private func promptToMoveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let isOnDMG = bundlePath.hasPrefix("/Volumes/")
        let isTranslocated = bundlePath.contains("/AppTranslocation/")
        guard isOnDMG || isTranslocated else { return }
        guard !UserDefaults.standard.bool(forKey: "suppressMoveToApplications") else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "\(AppInfo.displayName) is running from a disk image. Move it to your Applications folder for the best experience."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "suppressMoveToApplications")
        }
        guard response == .alertFirstButtonReturn else { return }

        let dest = URL(fileURLWithPath: "/Applications/\(AppInfo.displayName).app")
        let src = URL(fileURLWithPath: bundlePath)
        do {
            // Remove old version if present
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            // Relaunch from /Applications
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Preserve any cold-launch request that arrived before the user
            // accepted this move prompt. `-a` makes the copied bundle the
            // explicit recipient of both custom URLs and file URLs.
            task.arguments = ["-n", "-a", dest.path]
                + pendingOpenURLs.map(\.absoluteString)
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Could not move to Applications"
            errAlert.informativeText = "Please drag SimpleShot to your Applications folder manually.\n\n\(error.localizedDescription)"
            errAlert.runModal()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator.request(hasActiveWork: MediaExportCoordinator.shared.hasActiveJobs,
            drain: {
                await MediaExportCoordinator.shared.waitUntilIdle()
            }, terminate: { sender.terminate(nil) })
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Normal quit drains the recording writer and coordinated exports.
        // A force quit leaves the durable take in place.
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        HotkeyManager.shared.unregister()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu (required when no storyboard)

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SimpleShot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit SimpleShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        // Standard Close Window (Cmd+W) — routes to NSWindow.performClose(_:) via the
        // responder chain, so it closes whichever window is key (editor, settings, etc.)
        // without any window-specific handling.
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "")
        EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .undo, to: undoItem)
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "")
        EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .redo, to: redoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()
    }

    private func applyNormalStatusBarIcon() {
        if let button = statusItem.button {
            applyPreferredIconImage(to: button)
            // Use the NATIVE status-item menu (no custom click action). Showing
            // the menu by synthesizing a click from the button's mouse-down
            // action re-enters AppKit's mouse-tracking loop and can hang the main
            // thread (which also kills the global hotkey). The menu's delegate
            // handles modal dismissal + prewarm in menuWillOpen instead.
            button.target = nil
            button.action = nil
            statusItem.menu = statusBarMenu
        }
    }

    /// Sets the button image/title to the bundled icon; falls back to a text title
    /// if the asset is somehow missing so the item is never blank.
    private func applyPreferredIconImage(to button: NSStatusBarButton) {
        if let img = NSImage(named: "StatusBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 22, height: 22)
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "SimpleShot"
        }
    }

    /// Re-applies the menu bar icon. Invoked after a settings import so a stale
    /// preference in the imported file can't leave the item in an inconsistent state.
    func refreshStatusBarIcon() {
        guard let button = statusItem.button else { return }
        applyPreferredIconImage(to: button)
    }

    /// Re-apply the live side-effects of settings that were just bulk-imported
    /// (SettingsPortability). Cheap, well-defined effects are applied immediately;
    /// everything read once at launch takes effect after the relaunch prompt.
    func reapplySettingsAfterImport() {
        // Hotkeys: re-register every slot with the imported keycodes/modifiers.
        HotkeyManager.shared.unregisterAll()
        registerHotkey()

        // Launch-at-login: sync the login item to the imported value.
        if #available(macOS 13.0, *) {
            let enabled = UserDefaults.standard.bool(forKey: "launchAtLogin")
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                #if DEBUG
                print("reapplySettingsAfterImport: login item update failed: \(error)")
                #endif
            }
        }

        // Menu bar icon visibility + appearance.
        setMenuBarIconVisible(!UserDefaults.standard.bool(forKey: "hideMenuBarIcon"))
        refreshStatusBarIcon()
        rebuildStatusBarMenu()
    }

    /// Relaunch the app so settings read once at launch take effect. Launches a fresh
    /// instance via NSWorkspace (no shell, no sleep), then terminates this one once the
    /// new copy is up. `createsNewApplicationInstance` lets the replacement start before
    /// this process exits, so there's no window where no instance is running.
    static func relaunchApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func rebuildStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for itemID in CaptureMenuItemID.defaultOrder {
            menu.addItem(makeCaptureMenuItem(itemID))
        }

        // Capture Delay submenu
        let delayItem = NSMenuItem(title: L("Capture Delay"), action: nil, keyEquivalent: "")
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let delaySubmenu = NSMenu()
        delaySubmenu.autoenablesItems = false
        let currentDelay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        for seconds in [0, 3, 5, 10, 30] {
            let title = seconds == 0 ? L("None") : String(format: L("%d seconds"), seconds)
            let item = NSMenuItem(title: title, action: #selector(setDelaySeconds(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = seconds == currentDelay ? .on : .off
            delaySubmenu.addItem(item)
        }
        delayItem.submenu = delaySubmenu
        menu.addItem(delayItem)

        menu.addItem(NSMenuItem.separator())

        let openImageItem = NSMenuItem(title: L("Open Image..."), action: #selector(openImageFromMenu), keyEquivalent: "")
        openImageItem.target = self
        openImageItem.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        menu.addItem(openImageItem)

        let pasteImageItem = NSMenuItem(title: L("Open from Clipboard"), action: #selector(openImageFromClipboard), keyEquivalent: "")
        pasteImageItem.target = self
        pasteImageItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .openFromClipboard, to: pasteImageItem)
        menu.addItem(pasteImageItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: L("Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        prefsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L("Quit SimpleShot"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self  // menuWillOpen dismisses any modal + prewarms capture
        statusBarMenu = menu
        statusItem?.menu = menu
    }

    private func makeCaptureMenuItem(_ itemID: CaptureMenuItemID) -> NSMenuItem {
        let action: Selector
        switch itemID {
        case .captureArea: action = #selector(captureScreen)
        case .captureScreen: action = #selector(captureFullScreen)
        case .captureOCR: action = #selector(captureOCR)
        case .quickCapture: action = #selector(quickCapture)
        case .scrollCapture: action = #selector(scrollCapture)
        }

        let item = NSMenuItem(title: itemID.title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: itemID.symbolName, accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: itemID.hotkeySlot, to: item)
        return item
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        HotkeyManager.shared.registerAll(
            captureArea: { [weak self] in
                self?.perform(#selector(AppDelegate.captureScreenFromHotkey))
            },
            captureFullScreen: { [weak self] in
                self?.perform(#selector(AppDelegate.captureFullScreenFromHotkey))
            },
            captureOCR: { [weak self] in
                self?.perform(#selector(AppDelegate.captureOCRFromHotkey))
            },
            quickCapture: { [weak self] in
                self?.perform(#selector(AppDelegate.quickCaptureFromHotkey))
            },
            scrollCapture: { [weak self] in
                self?.perform(#selector(AppDelegate.scrollCaptureFromHotkey))
            },
            openFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.openImageFromClipboard() }
            }
        )
    }

    private var pendingFullScreen: Bool = false
    private var pendingOCRMode: Bool = false
    private var pendingQuickCaptureMode: Bool = false
    private var pendingScrollCaptureMode: Bool = false
    private var capturedWindowTitle: String?
    /// The app that was active before the overlay appeared — re-activated on dismiss.
    /// The app that was active before macshot showed its overlay.
    private var previousApp: NSRunningApplication?

    /// Titled macshot windows (editors, preferences, etc.) that were
    /// visible when capture started. We `orderOut` them so `NSApp.activate`
    /// during capture can't drag them in front of the user's frontmost app,
    /// then `orderFront` them when the overlay dismisses. Kept in the order
    /// they appeared so restoring preserves relative z-order.
    private var backgroundWindowRestoration = DeferredRestoration<NSWindow>()
    private var stashedBackgroundWindows: [NSWindow] { backgroundWindowRestoration.pending }
    private var backgroundWindowRestoreObserver: NSObjectProtocol?
    private var stashedWindowCloseObserver: NSObjectProtocol?

    /// Call when a macshot window closes. If no titled windows remain,
    /// switches to accessory activation policy and returns focus to
    /// the previous app (or the next regular app in line).
    func returnFocusIfNeeded() {
        let appToActivate = previousApp
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            // Windows we hid for the screenshot count as "visible" for
            // activation-policy purposes — they're coming back as soon as
            // the previous app regains focus, so we mustn't downgrade.
            let hasStashedWindows = !(self?.stashedBackgroundWindows.isEmpty ?? true)
            guard !hasVisibleWindows else { return }
            if !hasStashedWindows {
                NSApp.setActivationPolicy(.accessory)
            }
            if let prev = appToActivate, !prev.isTerminated,
               prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                Self.activateApp(prev)
            } else {
                // No known previous app — yield focus to whatever is frontmost.
                // Avoid NSApp.hide(nil) which can suspend the Carbon event loop
                // and break global hotkeys until the app is reactivated.
                Self.activateApp(
                    NSWorkspace.shared.runningApplications.first {
                        $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    } ?? NSWorkspace.shared.frontmostApplication ?? NSRunningApplication.current
                )
            }
        }
    }

    /// Activate another app using the modern cooperative activation API.
    static func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    // MARK: - Capture

    @objc private func captureScreen() {
        beginCaptureArea(fromMenu: true)
    }

    @objc private func captureScreenFromHotkey() {
        beginCaptureArea(fromMenu: false)
    }

    private func beginCaptureArea(fromMenu: Bool) {
        startCapture(fromMenu: fromMenu)
    }

    @objc private func captureFullScreen() {
        beginCaptureFullScreen(fromMenu: true)
    }

    @objc private func captureFullScreenFromHotkey() {
        beginCaptureFullScreen(fromMenu: false)
    }

    private func beginCaptureFullScreen(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingFullScreen = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func captureOCR() {
        beginCaptureOCR(fromMenu: true)
    }

    @objc private func captureOCRFromHotkey() {
        beginCaptureOCR(fromMenu: false)
    }

    private func beginCaptureOCR(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingOCRMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func quickCapture() {
        beginQuickCapture(fromMenu: true)
    }

    @objc private func quickCaptureFromHotkey() {
        beginQuickCapture(fromMenu: false)
    }

    private func beginQuickCapture(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingQuickCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func scrollCapture() {
        beginScrollCapture(fromMenu: true)
    }

    @objc private func scrollCaptureFromHotkey() {
        beginScrollCapture(fromMenu: false)
    }

    private func beginScrollCapture(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingScrollCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func setDelaySeconds(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "captureDelaySeconds")
        // Update checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = item.tag == sender.tag ? .on : .off
            }
        }
    }

    /// Whether a new capture can start right now. The `begin*` entry points set
    /// their pending mode flag (pendingOCRMode, …) BEFORE
    /// calling `startCapture`. If `startCapture` were to bail at its guards after
    /// the flag was set, the flag would strand and get applied to the *next*
    /// capture — e.g. a stranded `pendingOCRMode` makes a later screenshot spawn
    /// an unexpected OCR window (issue #276). So each `begin*` checks this FIRST
    /// and only sets its flag when a capture will actually run. We must not clear
    /// the flags inside `startCapture`'s `!isCapturing` guard, because during a
    /// delay-capture countdown `isCapturing` is already true and the pending mode
    /// belongs to that accepted (not-yet-consumed) capture.
    private var canStartCapture: Bool {
        !isCapturing
    }

    private func startCapture(fromMenu: Bool = false) {
        guard !isCapturing else { return }
        isCapturing = true
        captureSessionID &+= 1
        let sessionID = captureSessionID
        previousApp = NSWorkspace.shared.frontmostApplication
        capturedWindowTitle = nil
        let focusedWindowPID = previousApp?.processIdentifier
        resolveFocusedWindowTitleAsync(for: focusedWindowPID, sessionID: sessionID)

        // Clean up stale overlays without consuming previousApp — we just set it.
        dismissOverlays(refocusPreviousApp: false)
        isCapturing = true

        // Hide non-overlay titled windows so they don't end up in the screenshot.
        // Restored in dismissOverlays once capture is over.
        stashBackgroundWindows()

        let delay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")

        if delay > 0 {
            showPreCaptureCountdown(seconds: delay)
            return
        }

        performCapture(fromMenu: fromMenu)
    }

    private func showPreCaptureCountdown(seconds: Int) {
        // No display to show a countdown on (all asleep, or headless). Cancel
        // cleanly rather than leaving isCapturing stuck true. Deliberately not
        // performCapture(): its empty-result fallback shows the permission
        // onboarding screen, which would be misleading here (the problem is no
        // display, not missing permission), and a display that reappears mid
        // async-capture could still race controllers built from an empty
        // screen list, reproducing the same stuck state through a narrower door.
        guard let screen = NSScreen.preferred else {
            cancelPreCaptureCountdown()
            return
        }
        let size = NSSize(width: 140, height: 140)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        // Listen for Escape to cancel countdown — use both local and global monitors
        // Local catches keys when macshot is active; global catches when another app has focus
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelPreCaptureCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.removeDelayEscMonitors()
                self?.performCapture(fromMenu: false)
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func removeDelayEscMonitors() {
        if let m = delayEscMonitor { NSEvent.removeMonitor(m); delayEscMonitor = nil }
    }

    private func cancelPreCaptureCountdown() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        removeDelayEscMonitors()
        isCapturing = false
        pendingFullScreen = false
        pendingOCRMode = false
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        // Bring back any titled windows stashBackgroundWindows() hid before the
        // countdown started — a no-op if nothing was stashed.
        restoreBackgroundWindowsNow()
    }

    private func performCapture(fromMenu: Bool) {
        let screens = NSScreen.screens
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = screens.first { $0.frame.contains(mouseLocation) }

        // Kick off the screenshot capture on a background queue. Window
        // creation runs on main concurrently — both costs are paid in parallel.
        // CGWindowListCreateImage is used because it preserves transient UI
        // (menu extras, app menus, Raycast-style panels) that disappears once
        // anything steals focus. Overlay windows haven't been ordered-front yet
        // so they won't appear in the capture.
        let captureContext = ScreenCaptureManager.makeImmediateCaptureContext()
        let sessionID = captureSessionID

        // Pull (don't construct) overlay controllers from the persistent pool.
        // Each controller's NSPanel was created and warmed at launch / pool
        // rebuild, so WindowServer's per-window cache is already hot.
        var controllers: [OverlayWindowController] = []
        for screen in screens {
            let controller = pooledController(for: screen)
            controller.overlayDelegate = self
            controller.capturedWindowTitle = capturedWindowTitle
            if pendingOCRMode { controller.setAutoOCRMode() }
            if pendingQuickCaptureMode { controller.setAutoQuickSaveMode() }
            if pendingScrollCaptureMode { controller.setAutoScrollCaptureMode() }
            controllers.append(controller)
        }
        overlayControllers.append(contentsOf: controllers)

        let didApplyFullScreen = pendingFullScreen
        pendingOCRMode = false
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        pendingFullScreen = false

        // Run the screenshot capture now and dispatch back to main when done.
        // Window creation above already ran in parallel with the prep that the
        // background work still has to do.
        //
        // Prefer SCScreenshotManager: it never captures the mouse cursor, even the
        // enlarged shake-to-find / accessibility cursor,
        // which CGWindowListCreateImage cannot exclude (the cursor is a
        // WindowServer layer, not a window). On macOS 26+, use the rect-based
        // screenshot API to avoid SCShareableContent enumeration in the hot
        // path. Older SCK fallback still fetches fresh shareable content so
        // transient UI (menus, Spotlight) is preserved. If SCK fails or can't
        // cover every display, fall back to the synchronous CGWindowListCreateImage
        // path (which manually composites the cursor from the prebuilt context).
        Task { [weak self] in
            var captures: [ScreenCapture]? = nil
            if #available(macOS 14.0, *) {
                captures = await ScreenCaptureManager.captureAllScreensImmediatelySCK()
            }
            let finalCaptures = captures ?? ScreenCaptureManager.captureAllScreensImmediately(
                context: captureContext)
            await MainActor.run {
                guard let self = self, self.isCapturing,
                      self.captureSessionID == sessionID else { return }
                self.installAndShowOverlays(
                    captures: finalCaptures,
                    controllers: controllers,
                    mouseScreen: mouseScreen,
                    applyFullScreen: didApplyFullScreen)
            }
        }
    }

    /// Install screenshots into the pre-built overlay controllers and order
    /// them front. This is the single moment the overlay becomes visible.
    private func installAndShowOverlays(
        captures: [ScreenCapture],
        controllers: [OverlayWindowController],
        mouseScreen: NSScreen?,
        applyFullScreen: Bool
    ) {
        if captures.isEmpty {
            dismissOverlays(refocusPreviousApp: true)
            showOnboarding()
            return
        }

        let capturesByScreen = Dictionary(uniqueKeysWithValues: captures.map { ($0.screen, $0.image) })

        for controller in controllers {
            if let image = capturesByScreen[controller.screen] {
                controller.setScreenshot(image)
            }
            controller.showOverlay()
            let isMouseScreen = (controller.screen == mouseScreen)
                || (mouseScreen == nil && controller.screen == NSScreen.main)
            if applyFullScreen && isMouseScreen {
                controller.applyFullScreenSelection()
            }
        }

    }

    /// Returns the title of the frontmost window via CGWindowList (requires Screen Recording permission).
    nonisolated private static func focusedWindowTitle(forPID pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    private func resolveFocusedWindowTitleAsync(for pid: pid_t?, sessionID: UInt) {
        guard let pid = pid else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let title = Self.focusedWindowTitle(forPID: pid)
            DispatchQueue.main.async {
                guard let self = self, self.isCapturing, self.captureSessionID == sessionID else { return }
                self.capturedWindowTitle = title
                for controller in self.overlayControllers {
                    controller.capturedWindowTitle = title
                }
            }
        }
    }


    @objc private func handleShowAndOpenPrefs() {
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        openSettings()
    }

    @objc private func keyboardInputSourceDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildStatusBarMenu()
            self.settingsController?.refreshShortcutDisplaysForKeyboardLayout()
        }
    }

    @objc private func spaceDidChange() {
        guard !overlayControllers.isEmpty else { return }
        dismissOverlays()
    }

    private func dismissOverlays(refocusPreviousApp: Bool = true) {
        autoreleasepool {
            for controller in overlayControllers {
                controller.dismiss()
            }
            overlayControllers.removeAll()
        }
        isCapturing = false
        if refocusPreviousApp {
            // Restore AFTER another app takes focus so the stashed windows
            // come back behind it instead of on top. See
            // `scheduleBackgroundWindowRestore` for the timing logic.
            scheduleBackgroundWindowRestore()
            returnFocusIfNeeded()
        } else {
            // No focus switch coming — just bring them back immediately.
            restoreBackgroundWindowsNow()
        }
    }

    /// Hide non-overlay titled macshot windows so they can't be dragged in
    /// front of the user's frontmost app when the overlay activates.
    ///
    /// We only stash when another app was frontmost — that means the user is
    /// trying to screenshot something *other than* macshot, and any macshot
    /// windows still on screen are unintended background clutter. When
    /// macshot itself is frontmost the user presumably wants to capture one
    /// of its own windows, so we leave everything alone.
    private func stashBackgroundWindows() {
        clearBackgroundRestoreObservers()
        let macshotWasFrontmost = previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let additions = macshotWasFrontmost ? [] : NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled)
        }
        // Keep windows hidden by the preceding capture until this one can
        // restore them. Clearing the list here loses those windows permanently.
        backgroundWindowRestoration.begin(adding: additions)
        for window in additions { window.orderOut(nil) }
        guard !stashedBackgroundWindows.isEmpty else { return }
        stashedWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self = self, let window = note.object as? NSWindow else { return }
                    self.backgroundWindowRestoration.remove(window)
                    if self.stashedBackgroundWindows.isEmpty { self.clearBackgroundRestoreObservers() }
                }
            }
    }

    /// Restore only after another app regains focus, with a short fallback.
    /// Both callbacks belong to the scheduled generation, never a later stash.
    private func scheduleBackgroundWindowRestore() {
        if let observer = backgroundWindowRestoreObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            backgroundWindowRestoreObserver = nil
        }
        guard let token = backgroundWindowRestoration.schedule() else { return }
        backgroundWindowRestoreObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                    self?.restoreBackgroundWindows(ifCurrent: token)
                }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.restoreBackgroundWindows(ifCurrent: token)
        }
    }

    private func restoreBackgroundWindows(ifCurrent token: UInt64) {
        guard let windows = backgroundWindowRestoration.take(ifCurrent: token) else { return }
        clearBackgroundRestoreObservers()
        for window in windows { window.orderBack(nil) }
    }

    private func restoreBackgroundWindowsNow() {
        let windows = backgroundWindowRestoration.takeNow()
        clearBackgroundRestoreObservers()
        for window in windows { window.orderBack(nil) }
    }

    private func clearBackgroundRestoreObservers() {
        if let observer = backgroundWindowRestoreObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        backgroundWindowRestoreObserver = nil
        if let observer = stashedWindowCloseObserver { NotificationCenter.default.removeObserver(observer) }
        stashedWindowCloseObserver = nil
    }


    func runOCR(on image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !result.copyText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.copyText, forType: .string)
                    }

                    self.ocrController?.close()
                    let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
                    // Drop our reference when the window closes (incl. red-X),
                    // but only if it's still this controller (a newer OCR run
                    // may have replaced it).
                    ocr.onClose = { [weak self, weak ocr] in
                        if self?.ocrController === ocr { self?.ocrController = nil }
                    }
                    self.ocrController = ocr
                    ocr.show()
                }
            }
        }
    }

    private func saveImageToConfiguredFolder(_ image: NSImage) {
        ImageSaveService.saveToConfiguredFolder(image, panelLevel: .floating, activateApp: true)
    }

    /// Reports a failure the user needs to know about. Losing a capture without
    /// any indication is worse than any error message.
    func showFailureToast(_ message: String) {
        errorToastController?.dismiss()
        let toast = FailureToastController()
        errorToastController = toast
        toast.onDismiss = { [weak self] in
            self?.errorToastController = nil
        }
        toast.show(message: message)
    }

    // MARK: - Open Image

    @objc private func openImageFromMenu() {
        openImageWithPanel()
    }

    @objc private func openImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            let alert = NSAlert()
            alert.messageText = L("No Image on Clipboard")
            alert.informativeText = L("Copy an image to the clipboard first, then try again.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }
        DetachedEditorWindowController.open(image: image)
    }

    private func openImageWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .webP, .image]
        panel.message = "Choose an image to open in SimpleShot editor"

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openImageFile(url: url)
            }
        }
    }

    private func openImageFile(url: URL) {
        let image: NSImage
        if url.pathExtension.lowercased() == "webp",
           let data = try? Data(contentsOf: url),
           let decoded = try? WebPDecoder().decode(toNSImage: data, options: WebPDecoderOptions()) {
            image = decoded
        } else if let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            return
        }
        DetachedEditorWindowController.open(image: image)
    }

    /// Handle files opened via Finder "Open With", drag-to-dock, or command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReadyForOpenRequests else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        handleOpenURLs(urls)
    }

    private func handleOpenURLs(_ urls: [URL]) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "heif", "webp", "icns"]
        for url in urls {
            if url.scheme == "simpleshot" {
                let urlSchemeEnabled = UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true
                guard urlSchemeEnabled else { continue }
                if Self.screenCaptureURLActions.contains(url.host ?? "") {
                    if !isReadyForScreenCaptureURLs,
                       PermissionOnboardingController.hasScreenRecordingPermission() {
                        markScreenCaptureURLsReady()
                    }
                    if !isReadyForScreenCaptureURLs {
                        pendingScreenCaptureURLs.append(url)
                        showOnboarding()
                        continue
                    }
                }
                handleURLSchemeAction(url)
                continue
            }
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                openImageFile(url: url)
            }
        }
    }

    /// Handle simpleshot:// URL scheme actions from external tools (Raycast, Alfred, etc.).
    /// Usage: `open simpleshot://capture`, `open simpleshot://ocr`, etc.
    private static let screenCaptureURLActions: Set<String> = [
        "capture", "capture-fullscreen", "quick-capture",
        "ocr", "scroll-capture",
    ]

    private func handleURLSchemeAction(_ url: URL) {
        guard let action = url.host else { return }
        switch action {
        case "capture":             captureScreen()
        case "capture-fullscreen":  captureFullScreen()
        case "quick-capture":       quickCapture()
        case "ocr":                 captureOCR()
        case "scroll-capture":      scrollCapture()
        case "settings":            openSettings()
        case "open":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "file" })?.value {
                openImageFile(url: URL(fileURLWithPath: path))
            }
        default: break
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
            settingsController?.onHotkeyChanged = { [weak self] in
                self?.registerHotkey()
                self?.rebuildStatusBarMenu()
            }
            settingsController?.onEditorCommandShortcutChanged = { [weak self] in
                self?.setupMainMenu()
            }
        }
        settingsController?.showWindow()
    }

    // MARK: - Quit

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - OverlayWindowControllerDelegate

extension AppDelegate: OverlayWindowControllerDelegate {
    func overlayDidCancel(_ controller: OverlayWindowController) {
        dismissOverlays()

        // Focus is returned to the previous app by dismissOverlays() above.
    }

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?) {
        dismissOverlays()
        if let image = capturedImage {
            // "Also open in Editor" preference
            if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
                if let data = annotationData {
                    DetachedEditorWindowController.open(
                        image: data.rawImage,
                        annotations: data.annotations
                    )
                } else {
                    DetachedEditorWindowController.open(image: image)
                }
            }
        }
    }

    private func stitchCrossScreenCapture(primary: OverlayWindowController, others: [OverlayWindowController]) -> NSImage? {
        let primaryOrigin = primary.screen.frame.origin
        let primarySelRect = primary.selectionRect
        // Global selection rect
        let globalRect = NSRect(x: primarySelRect.origin.x + primaryOrigin.x,
                                y: primarySelRect.origin.y + primaryOrigin.y,
                                width: primarySelRect.width, height: primarySelRect.height)

        // Determine scale from primary screen
        let scale: CGFloat
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = primary.screen.backingScaleFactor
        }

        let pixelW = Int(globalRect.width * scale)
        let pixelH = Int(globalRect.height * scale)
        // Use the source image's color space to avoid expensive conversion
        let cs: CGColorSpace
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let cgCtx = CGContext(data: nil, width: pixelW, height: pixelH,
                                     bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        cgCtx.scaleBy(x: scale, y: scale)

        // Draw each screen's contribution
        let allControllers = [primary] + others
        for controller in allControllers {
            guard let screenshot = controller.screenshotImage else { continue }
            let screenFrame = controller.screen.frame
            // Where this screen sits relative to the global selection rect
            let drawX = screenFrame.origin.x - globalRect.origin.x
            let drawY = screenFrame.origin.y - globalRect.origin.y
            let drawRect = NSRect(x: drawX, y: drawY, width: screenFrame.width, height: screenFrame.height)

            cgCtx.saveGState()
            // Clip to only the portion within our output bounds
            cgCtx.clip(to: CGRect(x: 0, y: 0, width: globalRect.width, height: globalRect.height))
            let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            cgCtx.restoreGState()
        }

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }

    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?) {
        // The results window follows, so don't hand focus back to the previous app.
        dismissOverlays(refocusPreviousApp: false)

        if !result.copyText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.copyText, forType: .string)
        }

        ocrController?.close()
        let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
        ocr.onClose = { [weak self, weak ocr] in
            if self?.ocrController === ocr { self?.ocrController = nil }
        }
        ocrController = ocr
        ocr.show()
    }

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        if !AXIsProcessTrusted() {
            dismissOverlays()
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            let alert = NSAlert()
            alert.messageText = L("Accessibility Access Required")
            alert.informativeText = L("SimpleShot needs Accessibility permission for scroll capture. Please grant access in System Settings, then try again.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Open Settings"))
            alert.addButton(withTitle: L("Cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        scrollCaptureOverlayController = controller

        let scc = ScrollCaptureController(captureRect: rect, screen: screen)
        scc.excludedWindowIDs = overlayControllers.map { $0.windowNumber }
        scrollCaptureController = scc

        // Read max height for the overlay HUD progress bar
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000

        // Tell the triggering overlay to enter scroll capture mode
        controller.setScrollCaptureState(isActive: true, maxHeight: maxH)

        // Create live preview panel if there's space beside the capture region
        let overlayLevel = 257  // matches overlay window level
        if let previewPanel = ScrollCapturePreviewPanel(captureRect: rect, screen: screen, overlayLevel: overlayLevel) {
            previewPanel.orderFront(nil)
            scrollCapturePreviewPanel = previewPanel
        }

        scc.onStripAdded = { [weak self, weak controller] count in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: count, pixelSize: scc.stitchedPixelSize,
                autoScrolling: scc.autoScrollActive)
        }
        scc.onPreviewUpdated = { [weak self] image in
            self?.scrollCapturePreviewPanel?.updatePreview(image: image)
        }
        scc.onAutoScrollStarted = { [weak self, weak controller] in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
                autoScrolling: true)
        }
        scc.onSessionDone = { [weak self] finalImage in
            self?.handleScrollCaptureCompleted(finalImage: finalImage)
        }

        Task { await scc.startSession() }
    }

    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {
        scrollCaptureController?.stopSession()
        // onSessionDone fires asynchronously via handleScrollCaptureCompleted
    }

    func overlayDidRequestCancelScrollCapture(_ controller: OverlayWindowController) {
        // Esc cancels scroll capture: tear down WITHOUT delivering an image
        // (cancelSession never fires onSessionDone), so nothing is saved, copied,
        // or added to history. Mirrors the Accessibility-denied teardown block.
        let captureController = scrollCaptureController
        scrollCaptureController = nil
        // Detach callbacks first so even an already-in-flight initial capture
        // cannot report completion after cancellation.
        captureController?.onStripAdded = nil
        captureController?.onPreviewUpdated = nil
        captureController?.onAutoScrollStarted = nil
        captureController?.onSessionDone = nil
        captureController?.cancelSession()
        scrollCapturePreviewPanel?.close()
        scrollCapturePreviewPanel = nil
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        dismissOverlays()
    }

    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        let alert = NSAlert()
        alert.messageText = L("Accessibility Access Required")
        alert.informativeText = L("SimpleShot needs Accessibility permission to snap to individual interface elements. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {
        guard let scc = scrollCaptureController else { return }

        // If turning on, check Accessibility permission first
        if !scc.autoScrollActive {
            if !AXIsProcessTrusted() {
                // Cancel session without delivering a result, then dismiss overlays
                scc.cancelSession()
                scrollCaptureController = nil
                scrollCapturePreviewPanel?.close()
                scrollCapturePreviewPanel = nil
                scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
                scrollCaptureOverlayController = nil
                dismissOverlays()

                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
                let alert = NSAlert()
                alert.messageText = L("Accessibility Access Required")
                alert.informativeText = L("SimpleShot needs Accessibility permission to auto-scroll other apps. Please grant access in System Settings, then try again.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: L("Open Settings"))
                alert.addButton(withTitle: L("Cancel"))
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                return
            }
        }

        scc.toggleAutoScroll()
        let autoScrolling = scc.isActive && scc.autoScrollActive
        controller.updateScrollCaptureProgress(
            stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
            autoScrolling: autoScrolling)
    }

    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        for other in overlayControllers where other !== controller {
            other.clearSelection()
            other.setRemoteSelection(.zero)
        }
    }

    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in overlayControllers where other !== controller {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Update the primary screen's actual selection
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)

        // Update other secondary screens (not the caller — it manages its own remoteSelectionRect during drag)
        for other in overlayControllers where other !== controller && other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Final sync after remote resize — update primary, re-sync ALL secondaries, transfer focus
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)
        primary.makeKey()

        // Re-sync ALL secondary screens (including the caller) from the primary's authoritative rect
        let primarySel = primary.selectionRect
        let primaryGlobal = NSRect(x: primarySel.origin.x + primaryOrigin.x,
                                   y: primarySel.origin.y + primaryOrigin.y,
                                   width: primarySel.width, height: primarySel.height)
        for other in overlayControllers where other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: primaryGlobal.origin.x - otherOrigin.x,
                                   y: primaryGlobal.origin.y - otherOrigin.y,
                                   width: primaryGlobal.width, height: primaryGlobal.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        let others = overlayControllers.filter { $0 !== controller && $0.remoteSelectionRect.width >= 1 && $0.remoteSelectionRect.height >= 1 }
        guard !others.isEmpty else { return nil }
        return stitchCrossScreenCapture(primary: controller, others: others)
    }

    func overlayDidChangeSnapMode(_ controller: OverlayWindowController) {
        // Notify all other overlays to redraw (for multi-monitor setups)
        // When snap mode changes via Tab, all overlays need to update their helper text.
        for other in overlayControllers where other !== controller {
            other.refreshSnapMode()
        }
    }

    private func handleScrollCaptureCompleted(finalImage: NSImage?) {
        scrollCapturePreviewPanel?.close()
        scrollCapturePreviewPanel = nil
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        scrollCaptureController = nil

        dismissOverlays()

        guard let image = finalImage else { return }

        // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
        if mode == 1 || mode == 2 {
            ImageEncoder.copyToClipboard(image)
        }
        if mode == 0 || mode == 2 {
            saveImageToConfiguredFolder(image)
        }

        if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
            DetachedEditorWindowController.open(image: image)
        }
    }

}

// MARK: - NSMenuDelegate (status bar menu)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Dismiss any active modal before the menu shows, and pre-warm
        // ScreenCaptureKit content while the user browses.
        guard menu === statusBarMenu else { return }
        ScreenCaptureManager.prewarm()
        if let modalWin = NSApp.modalWindow {
            NSApp.stopModal()
            modalWin.close()
        }
    }
}
