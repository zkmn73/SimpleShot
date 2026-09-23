import Cocoa
import Carbon
import ServiceManagement
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Settings window that intercepts Cmd+Q to close itself instead of quitting the app.
private class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyboardShortcutMatcher.matches(event, character: "q", modifiers: .command) {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    // MARK: - Toolbar tab definitions
    private struct TabDef {
        let id: String
        let label: String
        let symbolName: String
        let legacyImageName: String  // fallback for older macOS if needed
    }
    private static var tabDefs: [TabDef] {
        var tabs: [TabDef] = [
            TabDef(id: "general",   label: "General",   symbolName: "gearshape",                 legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "capture",   label: "Capture",   symbolName: "camera.viewfinder",         legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "shortcuts", label: "Shortcuts", symbolName: "keyboard",                  legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "tools",     label: "Tools",     symbolName: "paintbrush",                legacyImageName: NSImage.preferencesGeneralName),
        ]
        tabs.append(TabDef(id: "about", label: "About", symbolName: "info.circle", legacyImageName: NSImage.preferencesGeneralName))
        return tabs
    }

    private var tabContentContainer: NSView!
    private var tabContentViews: [String: NSView] = [:]
    private var currentTabID: String = "general"


    private var hotkeyFields: [HotkeyManager.HotkeySlot: NSTextField] = [:]
    private var hotkeyButtons: [HotkeyManager.HotkeySlot: NSButton] = [:]
    private var recordingSlot: HotkeyManager.HotkeySlot?
    private var commandShortcutFields: [EditorCommandShortcutManager.Action: NSTextField] = [:]
    private var commandShortcutButtons: [EditorCommandShortcutManager.Action: NSButton] = [:]
    private var recordingCommandAction: EditorCommandShortcutManager.Action?
    private var toolShortcutFields: [ToolShortcutManager.Action: NSTextField] = [:]
    private var toolShortcutButtons: [ToolShortcutManager.Action: NSButton] = [:]
    private var showToolShortcutsInTooltipsCheckbox: NSButton!
    private var recordingToolAction: ToolShortcutManager.Action?
    private var savePathField: NSTextField!
    private var saveActionPopup: NSPopUpButton!
    private var ocrActionPopup: NSPopUpButton!
    private var copySoundCheckbox: NSButton!
    // rememberSelectionCheckbox removed — selection is always saved for "Capture Last Area"
    private var rememberToolCheckbox: NSButton!
    private var thumbnailCheckbox: NSButton!
    private var thumbnailAutoDismissStepper: NSStepper!
    private var thumbnailAutoDismissField: NSTextField!
    private var thumbnailStackingPopup: NSPopUpButton!
    private var thumbnailCornerPopup: NSPopUpButton!
    private var thumbnailLetterboxCheckbox: NSButton!
    private var thumbnailScaleLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var hideMenuBarIconCheckbox: NSButton!
    private var snapGuidesCheckbox: NSButton!
    private var boundarySnapCheckbox: NSButton!
    private var browserElementSnapCheckbox: NSButton!
    private var captureCursorCheckbox: NSButton!
    private var doubleClickToCopyCheckbox: NSButton!
    private var hideCaptureInstructionsCheckbox: NSButton!
    private var disableSelectionShadowCheckbox: NSButton!
    private var filenameTemplateField: NSTextField!
    private var filenameTemplatePreview: NSTextField!
    private var autoUpdateCheckbox: NSButton!
    private var betaUpdateCheckbox: NSButton!
    private var accentColorWell: NSColorWell!
    private var iconColorWell: NSColorWell!
    private var bgColorWell: NSColorWell!
    private var themePresetPopup: NSPopUpButton!
    private var quickModePopup: NSPopUpButton!
    private var quickCaptureOpenEditorCheckbox: NSButton!
    private var closeEditorAfterCopyCheckbox: NSButton!
    private var imageFormatPopup: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityLabel: NSTextField!
    private var qualityRowLabel: NSTextField!
    private var downscaleRetinaCheckbox: NSButton!
    private var captureMenuOrder: [CaptureMenuItemID] = []
    private var captureMenuOrderRowsStack: NSStackView?
    // embedColorProfileCheckbox removed — native color profile is always embedded
    private var localMonitor: Any?
    // Scroll capture controls
    private var scrollAutoScrollCheckbox: NSButton!
    private var scrollSpeedPopup: NSPopUpButton!
    private var scrollMaxHeightField: NSTextField!
    private var scrollMaxHeightStepper: NSStepper!
    private var scrollFrozenDetectionCheckbox: NSButton!

    var onHotkeyChanged: (() -> Void)?
    var onEditorCommandShortcutChanged: (() -> Void)?

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(BuildVariant.displayName) \(L("Settings"))"
        window.center()
        window.isReleasedWhenClosed = false
        // Window is non-resizable (no .resizable in styleMask), so content size
        // is locked. We also set the content size explicitly after the toolbar
        // is installed (in setupUI) to override NSToolbar's auto-sizing.
        super.init(window: window)
        window.delegate = self
        setupUI()
        loadSettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Top-level layout

    private func setupUI() {
        guard let window = window, let cv = window.contentView else { return }

        // Toolbar (preference style — icon + label, Shottr-like)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier("general")
        // Re-apply content size after toolbar install, since NSToolbar can
        // resize the window to fit its items.
        //
        // Width went from 560 → 620 to accommodate longer translated
        // strings (issue #130 — Polish "Szybkie przechwycenie:" + the
        // "Automatycznie zamazuj dane wrażliwe" checkbox both overflowed
        // the old layout). The extra 60pt flows evenly across the two
        // toggle-grid columns so Polish/German/Dutch labels fit on one
        // line instead of wrapping.
        window.setContentSize(NSSize(width: 620, height: 520))

        // Build all tab content views up front (preserves existing behavior — nothing lazy-created)
        tabContentViews["general"]   = makeGeneralTabView()
        tabContentViews["capture"]   = makeCaptureTabView()
        tabContentViews["shortcuts"] = makeShortcutsTabView()
        tabContentViews["tools"]     = makeToolsTabView()
        tabContentViews["about"]     = makeAboutTabView()

        // Container that swaps content views
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tabContentContainer = container

        // Footer separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Footer labels
        let madeBy = NSTextField(labelWithString: "\(L("Made by")) sw33tLie")
        madeBy.font = NSFont.systemFont(ofSize: 11)
        madeBy.textColor = .secondaryLabelColor
        madeBy.translatesAutoresizingMaskIntoConstraints = false

        let linkBtn = NSButton(title: "github.com/sw33tLie/macshot", target: self, action: #selector(openGitHub))
        linkBtn.bezelStyle = .inline
        linkBtn.isBordered = false
        linkBtn.font = NSFont.systemFont(ofSize: 11)
        linkBtn.attributedTitle = NSAttributedString(string: "github.com/sw33tLie/macshot", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        linkBtn.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView(views: [madeBy, NSView(), linkBtn])
        footerStack.orientation = .horizontal
        footerStack.spacing = 0
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(container)
        cv.addSubview(sep)
        cv.addSubview(footerStack)

        NSLayoutConstraint.activate([
            // Content container fills above the footer
            container.topAnchor.constraint(equalTo: cv.topAnchor),
            container.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: sep.topAnchor),

            // Footer separator
            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -6),
            sep.heightAnchor.constraint(equalToConstant: 1),

            // Footer
            footerStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            footerStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            footerStack.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Show initial tab
        showTab(id: "general")
    }

    private func showTab(id: String) {
        guard let container = tabContentContainer, let view = tabContentViews[id] else { return }
        // Remove existing content
        for sub in container.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        currentTabID = id
        window?.title = "\(BuildVariant.displayName) \(L("Settings")) — \(L(Self.tabDefs.first(where: { $0.id == id })?.label ?? ""))"
    }

    @objc private func toolbarTabSelected(_ sender: NSToolbarItem) {
        showTab(id: sender.itemIdentifier.rawValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.tabDefs.map { NSToolbarItem.Identifier($0.id) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let def = Self.tabDefs.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L(def.label)
        item.paletteLabel = L(def.label)
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: def.symbolName, accessibilityDescription: def.label)
        } else {
            item.image = NSImage(named: def.legacyImageName)
        }
        item.target = self
        item.action = #selector(toolbarTabSelected(_:))
        return item
    }

    // MARK: - General Tab

    /// NSStackView subclass with flipped coordinates so content pins to the top
    /// of its scroll view (default AppKit origin is bottom-left, which would
    /// push short content to the bottom of a tall clip view).
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    /// Small SF Symbol icon that reports hover enter/exit via callback. Used for
    /// hover-to-show info popovers next to settings controls.
    fileprivate final class HoverPopoverIconView: NSImageView {
        /// Called with (the view, true) on hover enter and (view, false) on exit.
        var onHover: ((NSView, Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        init(image: NSImage?, tintColor: NSColor, toolTip: String?) {
            super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            self.image = image
            self.contentTintColor = tintColor
            self.toolTip = toolTip
            self.imageScaling = .scaleProportionallyDown
            self.translatesAutoresizingMaskIntoConstraints = false
            self.widthAnchor.constraint(equalToConstant: 16).isActive = true
            self.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
        override func mouseExited(with event: NSEvent)  { onHover?(self, false) }
    }

    /// Creates a scrollable vertical stack matching the layout used by all settings tabs.
    private func makeSettingsScrollStack() -> (NSScrollView, NSStackView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return (scroll, stack)
    }

    /// Finalizes a settings tab by wiring the stack into the scroll view.
    private func finalizeSettingsStack(scroll: NSScrollView, stack: NSStackView) {
        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            // no bottom constraint — stack grows to fit content, scroll handles overflow
        ])
    }

    private func makeGeneralTabView() -> NSView {
        let (scroll, stack) = makeSettingsScrollStack()

        // ── Application ──────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Application")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: L("Launch at login"), target: self, action: #selector(launchAtLoginChanged(_:)))
        stack.addArrangedSubview(indented(launchAtLoginCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        hideMenuBarIconCheckbox = NSButton(checkboxWithTitle: L("Hide menu bar icon"), target: self, action: #selector(hideMenuBarIconChanged(_:)))
        stack.addArrangedSubview(indented(hideMenuBarIconCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let hideNote = NSTextField(wrappingLabelWithString: L("Hotkeys still work. To show the icon again, re-launch macshot."))
        hideNote.font = NSFont.systemFont(ofSize: 10)
        hideNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(hideNote))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let urlSchemeCheckbox = NSButton(checkboxWithTitle: L("Enable macshot:// URL scheme"), target: self, action: #selector(urlSchemeChanged(_:)))
        urlSchemeCheckbox.state = (UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true) ? .on : .off

        let urlSchemeInfoIcon = HoverPopoverIconView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("URL scheme info")),
            tintColor: .secondaryLabelColor,
            toolTip: L("Show supported URL scheme commands")
        )
        urlSchemeInfoIcon.onHover = { [weak self] sourceView, shown in
            if shown { self?.showURLSchemeInfoPopover(near: sourceView) }
            // On exit, do nothing — the popover is .transient, so clicking
            // anywhere outside it closes it. This lets the user move into the
            // popover to read/copy without it vanishing.
        }

        let urlSchemeRow = NSStackView(views: [urlSchemeCheckbox, urlSchemeInfoIcon])
        urlSchemeRow.orientation = .horizontal
        urlSchemeRow.spacing = 4
        urlSchemeRow.alignment = .centerY
        stack.addArrangedSubview(indented(urlSchemeRow))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        autoUpdateCheckbox = NSButton(checkboxWithTitle: L("Check for updates automatically"), target: self, action: #selector(autoUpdateChanged(_:)))
        stack.addArrangedSubview(indented(autoUpdateCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        betaUpdateCheckbox = NSButton(checkboxWithTitle: L("Check for beta updates"), target: self, action: #selector(betaUpdateChanged(_:)))
        stack.addArrangedSubview(indented(betaUpdateCheckbox))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Appearance ───────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Appearance")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Theme preset dropdown
        themePresetPopup = NSPopUpButton()
        for preset in ThemePreset.all {
            themePresetPopup.addItem(withTitle: L(preset.name))
        }
        themePresetPopup.addItem(withTitle: L("Custom"))
        themePresetPopup.target = self
        themePresetPopup.action = #selector(themePresetChanged(_:))
        stack.addArrangedSubview(indented(labeledRow(L("Theme:"), controls: [themePresetPopup])))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Three color wells in a single row with labels underneath
        accentColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        accentColorWell.color = ToolbarLayout.accentColor
        accentColorWell.target = self
        accentColorWell.action = #selector(accentColorChanged(_:))

        iconColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        iconColorWell.color = ToolbarLayout.iconColor
        iconColorWell.target = self
        iconColorWell.action = #selector(iconColorChanged(_:))

        bgColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        bgColorWell.color = ToolbarLayout.bgColor
        bgColorWell.target = self
        bgColorWell.action = #selector(bgColorChanged(_:))

        let accentCol = makeColorColumn(well: accentColorWell, caption: L("Accent"))
        let iconCol   = makeColorColumn(well: iconColorWell,   caption: L("Icon"))
        let bgCol     = makeColorColumn(well: bgColorWell,     caption: L("Background"))

        let colorsRow = NSStackView(views: [accentCol, iconCol, bgCol])
        colorsRow.orientation = .horizontal
        colorsRow.alignment = .top
        colorsRow.spacing = 20
        stack.addArrangedSubview(indented(colorsRow))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Sync preset popup to current colors
        updateThemePresetSelection()

        // ── Settings Backup ──────────────────────────────────
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionHeader(L("Settings Backup")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let exportBtn = NSButton(title: L("Export Settings…"), target: self, action: #selector(exportSettingsClicked(_:)))
        exportBtn.bezelStyle = .rounded
        let importBtn = NSButton(title: L("Import Settings…"), target: self, action: #selector(importSettingsClicked(_:)))
        importBtn.bezelStyle = .rounded

        let backupButtonsRow = NSStackView(views: [exportBtn, importBtn])
        backupButtonsRow.orientation = .horizontal
        backupButtonsRow.spacing = 8
        backupButtonsRow.alignment = .centerY
        stack.addArrangedSubview(indented(backupButtonsRow))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        let backupNote = NSTextField(wrappingLabelWithString: L("Export your preferences to a file to move them to another Mac or a clean install. Your save folder is not included. Settings are stored inside macshot's app container."))
        backupNote.font = NSFont.systemFont(ofSize: 10)
        backupNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(backupNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        let revealSettingsBtn = NSButton(title: L("Reveal Settings File in Finder"), target: self, action: #selector(revealSettingsFileClicked(_:)))
        revealSettingsBtn.bezelStyle = .inline
        revealSettingsBtn.controlSize = .small
        stack.addArrangedSubview(indented(revealSettingsBtn))

        finalizeSettingsStack(scroll: scroll, stack: stack)
        return scroll
    }

    // MARK: - Settings Backup actions

    @objc private func exportSettingsClicked(_ sender: NSButton) {
        guard let window = window else { return }
        let result: SettingsPortability.ExportResult
        do {
            result = try SettingsPortability.exportData()
        } catch {
            presentBackupError(error, title: L("Export failed"))
            return
        }

        let panel = NSSavePanel()
        panel.title = L("Export Settings")
        panel.nameFieldStringValue = SettingsPortability.suggestedExportFilename()
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try result.data.write(to: url)
                if !result.skippedLargeKeys.isEmpty {
                    let message: String
                    if result.skippedLargeKeys == ["beautifyCustomBgImageData"] {
                        message = L("Your custom Beautify background image was too large to include. Everything else was saved.")
                    } else {
                        message = L("A few large items were too big to include. Everything else was saved.")
                    }
                    self?.presentBackupInfo(title: L("Settings exported"), message: message)
                }
            } catch {
                self?.presentBackupError(error, title: L("Export failed"))
            }
        }
    }

    @objc private func importSettingsClicked(_ sender: NSButton) {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = L("Import Settings")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.confirmAndImport(from: url)
        }
    }

    private func confirmAndImport(from url: URL) {
        guard let window = window else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentBackupError(error, title: L("Import failed"))
            return
        }

        let confirm = NSAlert()
        confirm.messageText = L("Replace your current settings?")
        confirm.informativeText = L("Importing will replace your current preferences with the ones in this file. Your save folder is kept. This cannot be undone.")
        confirm.addButton(withTitle: L("Import"))
        confirm.addButton(withTitle: L("Cancel"))
        confirm.alertStyle = .warning
        confirm.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.performImport(data)
        }
    }

    private func performImport(_ data: Data) {
        let result: SettingsPortability.ImportResult
        do {
            result = try SettingsPortability.importData(data)
        } catch {
            presentBackupError(error, title: L("Import failed"))
            return
        }

        // Re-apply the cheap live side-effects immediately; everything else takes effect on relaunch.
        (NSApp.delegate as? AppDelegate)?.reapplySettingsAfterImport()

        // Rebuild this window's controls so the visible tabs reflect the imported values.
        rebuildAllTabsAfterImport()

        let alert = NSAlert()
        alert.messageText = L("Settings imported")
        alert.informativeText = String(format: L("%d settings were applied. Relaunch macshot to apply all changes."), result.appliedCount)
        alert.addButton(withTitle: L("Relaunch Now"))
        alert.addButton(withTitle: L("Later"))
        guard let window = window else { return }
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            AppDelegate.relaunchApp()
        }
    }

    private func rebuildAllTabsAfterImport() {
        let previouslySelected = currentTabID
        tabContentViews.removeAll()
        tabContentViews["general"] = makeGeneralTabView()
        tabContentViews["capture"] = makeCaptureTabView()
        tabContentViews["shortcuts"] = makeShortcutsTabView()
        tabContentViews["tools"] = makeToolsTabView()
        tabContentViews["about"] = makeAboutTabView()
        showTab(id: previouslySelected)
    }

    @objc private func revealSettingsFileClicked(_ sender: NSButton) {
        let prefsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Preferences", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sw33tlie.macshot.macshot"
        let plist = prefsDir.appendingPathComponent("\(bundleID).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            NSWorkspace.shared.activateFileViewerSelecting([plist])
        } else {
            NSWorkspace.shared.open(prefsDir)
        }
    }

    private func presentBackupError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func presentBackupInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    // MARK: - Capture Tab

    private func makeCaptureTabView() -> NSView {
        let (scroll, stack) = makeSettingsScrollStack()

        // ── Capture ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Capture")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Enter key action
        quickModePopup = NSPopUpButton()
        quickModePopup.addItems(withTitles: [L("Save to file"), L("Copy to clipboard"), L("Save + copy to clipboard"), L("Do nothing")])
        quickModePopup.target = self
        quickModePopup.action = #selector(quickModeChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Enter / Quick Capture:"), controls: [quickModePopup]))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        quickCaptureOpenEditorCheckbox = NSButton(checkboxWithTitle: L("Also open in Editor"), target: self, action: #selector(quickCaptureOpenEditorChanged(_:)))
        stack.addArrangedSubview(indented(quickCaptureOpenEditorCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        closeEditorAfterCopyCheckbox = NSButton(checkboxWithTitle: L("Close editor after copying"), target: self, action: #selector(closeEditorAfterCopyChanged(_:)))
        stack.addArrangedSubview(indented(closeEditorAfterCopyCheckbox))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // OCR & QR action dropdown
        ocrActionPopup = NSPopUpButton()
        ocrActionPopup.addItems(withTitles: [
            L("Show window + copy to clipboard"),
            L("Show window only"),
            L("Copy to clipboard only"),
        ])
        ocrActionPopup.target = self
        ocrActionPopup.action = #selector(ocrActionChanged(_:))

        stack.addArrangedSubview(labeledRow(L("OCR & QR Capture:"), controls: [ocrActionPopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Checkboxes
        copySoundCheckbox = NSButton(checkboxWithTitle: L("Play sound on capture"), target: self, action: #selector(copySoundChanged(_:)))
        rememberToolCheckbox = NSButton(checkboxWithTitle: L("Remember last selected tool"), target: self, action: #selector(rememberToolChanged(_:)))
        thumbnailCheckbox = NSButton(checkboxWithTitle: L("Show floating thumbnail after capture"), target: self, action: #selector(thumbnailChanged(_:)))
        snapGuidesCheckbox = NSButton(checkboxWithTitle: L("Show snap alignment guides"), target: self, action: #selector(snapGuidesChanged(_:)))
        boundarySnapCheckbox = NSButton(checkboxWithTitle: L("Snap selection edges to image boundaries"), target: self, action: #selector(boundarySnapChanged(_:)))
        browserElementSnapCheckbox = NSButton(
            checkboxWithTitle: L("Enhance browser and Electron element snapping"),
            target: self,
            action: #selector(browserElementSnapChanged(_:)))
        captureCursorCheckbox = NSButton(checkboxWithTitle: L("Capture mouse cursor in screenshot"), target: self, action: #selector(captureCursorChanged(_:)))
        doubleClickToCopyCheckbox = NSButton(checkboxWithTitle: L("Double-click selection to copy"), target: self, action: #selector(doubleClickToCopyChanged(_:)))
        hideCaptureInstructionsCheckbox = NSButton(checkboxWithTitle: L("Hide capture instructions"), target: self, action: #selector(hideCaptureInstructionsChanged(_:)))
        disableSelectionShadowCheckbox = NSButton(checkboxWithTitle: L("Disable shadow outside selection"), target: self, action: #selector(disableSelectionShadowChanged(_:)))
        filenameTemplateField = NSTextField()
        filenameTemplateField.placeholderString = FilenameFormatter.defaultTemplate
        filenameTemplateField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        filenameTemplateField.stringValue = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        filenameTemplateField.target = self
        filenameTemplateField.action = #selector(filenameTemplateCommitted(_:))
        filenameTemplateField.delegate = self
        filenameTemplateField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        filenameTemplatePreview = NSTextField(labelWithString: "")
        filenameTemplatePreview.font = NSFont.systemFont(ofSize: 10)
        filenameTemplatePreview.textColor = .secondaryLabelColor
        filenameTemplatePreview.lineBreakMode = .byTruncatingMiddle

        for cb in [copySoundCheckbox!, rememberToolCheckbox!, thumbnailCheckbox!] {
            stack.addArrangedSubview(indented(cb))
            stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        }

        // Thumbnail auto-dismiss stepper
        thumbnailAutoDismissField = NSTextField()
        thumbnailAutoDismissField.isEditable = false
        thumbnailAutoDismissField.isSelectable = false
        thumbnailAutoDismissField.alignment = .center
        thumbnailAutoDismissField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        thumbnailAutoDismissStepper = NSStepper()
        thumbnailAutoDismissStepper.minValue = 0
        thumbnailAutoDismissStepper.maxValue = 60
        thumbnailAutoDismissStepper.increment = 1
        thumbnailAutoDismissStepper.target = self
        thumbnailAutoDismissStepper.action = #selector(thumbnailAutoDismissChanged(_:))

        let dismissNote = NSTextField(labelWithString: L("sec (0 = never)"))
        dismissNote.font = NSFont.systemFont(ofSize: 11)
        dismissNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(indented(labeledRow(L("  Dismiss after:"), controls: [thumbnailAutoDismissField!, thumbnailAutoDismissStepper!, dismissNote])))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Thumbnail stacking popup
        thumbnailStackingPopup = NSPopUpButton()
        thumbnailStackingPopup.addItems(withTitles: [L("Stack (keep all)"), L("Replace (show only latest)")])
        thumbnailStackingPopup.target = self
        thumbnailStackingPopup.action = #selector(thumbnailStackingChanged(_:))

        stack.addArrangedSubview(indented(labeledRow(L("  Multiple previews:"), controls: [thumbnailStackingPopup!])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        thumbnailCornerPopup = NSPopUpButton()
        thumbnailCornerPopup.addItems(withTitles: [L("Bottom Right"), L("Bottom Left"), L("Top Right"), L("Top Left")])
        thumbnailCornerPopup.target = self
        thumbnailCornerPopup.action = #selector(thumbnailCornerChanged(_:))
        stack.addArrangedSubview(indented(labeledRow(L("  Position:"), controls: [thumbnailCornerPopup!])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let sizeSlider = NSSlider(value: UserDefaults.standard.object(forKey: "thumbnailScale") as? Double ?? 1.0,
                                   minValue: 0.5, maxValue: 2.0, target: self, action: #selector(thumbnailScaleChanged(_:)))
        sizeSlider.controlSize = .small
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        thumbnailScaleLabel = NSTextField(labelWithString: scalePercentString(sizeSlider.doubleValue))
        thumbnailScaleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        thumbnailScaleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(labeledRow(L("  Preview size:"), controls: [sizeSlider, thumbnailScaleLabel])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        thumbnailLetterboxCheckbox = NSButton(
            checkboxWithTitle: L("Fit image in preview (letterbox)"),
            target: self,
            action: #selector(thumbnailLetterboxChanged(_:))
        )
        stack.addArrangedSubview(indented(thumbnailLetterboxCheckbox))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(snapGuidesCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(boundarySnapCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(browserElementSnapCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)
        let browserElementSnapNote = NSTextField(wrappingLabelWithString: L("Builds the target app's accessibility tree in Element mode. Disable this if a browser or Electron app becomes slow or has input issues."))
        browserElementSnapNote.font = NSFont.systemFont(ofSize: 10)
        browserElementSnapNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(browserElementSnapNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(captureCursorCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(doubleClickToCopyCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(hideCaptureInstructionsCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(disableSelectionShadowCheckbox))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Output ───────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Output")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Default save action
        saveActionPopup = NSPopUpButton()
        for action in SaveActionPreference.allCases {
            saveActionPopup.addItem(withTitle: action.title)
            saveActionPopup.lastItem?.representedObject = action.rawValue
        }
        saveActionPopup.target = self
        saveActionPopup.action = #selector(saveActionChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Save action:"), controls: [saveActionPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Save folder
        savePathField = NSTextField()
        savePathField.isEditable = false
        savePathField.isSelectable = false
        savePathField.lineBreakMode = .byTruncatingMiddle

        let browseBtn = NSButton(title: L("Browse…"), target: self, action: #selector(browseSavePath(_:)))
        browseBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow(L("Save folder:"), controls: [savePathField, browseBtn]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Filename template
        let filenameResetBtn = NSButton(title: L("Reset"), target: self, action: #selector(filenameTemplateReset(_:)))
        filenameResetBtn.bezelStyle = .rounded

        let filenameInfoIcon = HoverPopoverIconView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("Filename tokens")),
            tintColor: .secondaryLabelColor,
            toolTip: L("Show available filename tokens")
        )
        filenameInfoIcon.onHover = { [weak self] sourceView, shown in
            if shown { self?.showFilenameTemplateInfoPopover(near: sourceView) }
        }

        stack.addArrangedSubview(labeledRow(L("Filename:"), controls: [filenameTemplateField, filenameInfoIcon, filenameResetBtn]))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(filenameTemplatePreview))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        updateFilenamePreview()

        // Image format
        imageFormatPopup = NSPopUpButton()
        for format in ImageEncoder.availableFormats {
            imageFormatPopup.addItem(withTitle: format.displayName)
            imageFormatPopup.lastItem?.representedObject = format.rawValue
        }
        imageFormatPopup.target = self
        imageFormatPopup.action = #selector(imageFormatChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Image format:"), controls: [imageFormatPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Quality (applies to lossy formats: JPEG, HEIC, WebP, AVIF)
        qualitySlider = NSSlider()
        qualitySlider.minValue = 10
        qualitySlider.maxValue = 100
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        qualityLabel = NSTextField(labelWithString: String(format: L("%d%%"), 85))
        qualityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        qualityRowLabel = NSTextField(labelWithString: L("Quality:"))
        qualityRowLabel.font = NSFont.systemFont(ofSize: 13)
        qualityRowLabel.alignment = .right
        qualityRowLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityRowLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let qualityRow = NSStackView(views: [qualityRowLabel, qualitySlider, qualityLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8
        qualityRow.alignment = .centerY
        qualityRow.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(qualityRow)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Downscale Retina
        downscaleRetinaCheckbox = NSButton(checkboxWithTitle: L("Save at standard resolution (1x)"), target: self, action: #selector(downscaleRetinaChanged(_:)))
        stack.addArrangedSubview(indented(downscaleRetinaCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let downscaleNote = NSTextField(labelWithString: L("Halves dimensions on Retina displays, ~4x smaller files"))
        downscaleNote.font = NSFont.systemFont(ofSize: 10)
        downscaleNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(indented(downscaleNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Color profile is always embedded (native display profile) — no toggle needed.

        // ── Menu Bar Order ──────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Menu Bar Order")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let menuOrderNote = NSTextField(wrappingLabelWithString: L("Choose the order of capture actions in the macshot menu bar menu."))
        menuOrderNote.font = NSFont.systemFont(ofSize: 10)
        menuOrderNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(menuOrderNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        captureMenuOrder = CaptureMenuItemID.orderedItems()
        stack.addArrangedSubview(indented(makeCaptureMenuOrderView()))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let resetMenuOrderButton = NSButton(title: L("Reset to default"), target: self, action: #selector(resetCaptureMenuOrder(_:)))
        resetMenuOrderButton.bezelStyle = .rounded
        stack.addArrangedSubview(indented(resetMenuOrderButton))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Scroll Capture ────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Scroll Capture")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        scrollAutoScrollCheckbox = NSButton(checkboxWithTitle: L("Auto-scroll (sends synthetic scroll events)"),
                                            target: self, action: #selector(scrollAutoScrollChanged(_:)))
        stack.addArrangedSubview(scrollAutoScrollCheckbox)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollSpeedPopup = NSPopUpButton()
        scrollSpeedPopup.addItems(withTitles: [L("Slow"), L("Medium"), L("Fast"), L("Very fast")])
        scrollSpeedPopup.target = self
        scrollSpeedPopup.action = #selector(scrollSpeedChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Scroll speed:"), controls: [scrollSpeedPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollMaxHeightField = NSTextField()
        scrollMaxHeightField.isEditable = false
        scrollMaxHeightField.isSelectable = false
        scrollMaxHeightField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        scrollMaxHeightField.translatesAutoresizingMaskIntoConstraints = false
        scrollMaxHeightField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        scrollMaxHeightStepper = NSStepper()
        scrollMaxHeightStepper.minValue = 0
        scrollMaxHeightStepper.maxValue = 100000
        scrollMaxHeightStepper.increment = 5000
        scrollMaxHeightStepper.valueWraps = false
        scrollMaxHeightStepper.target = self
        scrollMaxHeightStepper.action = #selector(scrollMaxHeightChanged(_:))

        let maxHeightNote = NSTextField(labelWithString: L("px (0 = unlimited)"))
        maxHeightNote.font = .systemFont(ofSize: 11)
        maxHeightNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(labeledRow(L("Max height:"), controls: [scrollMaxHeightField, scrollMaxHeightStepper, maxHeightNote]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollFrozenDetectionCheckbox = NSButton(checkboxWithTitle: L("Detect fixed/sticky headers"),
                                                 target: self, action: #selector(scrollFrozenDetectionChanged(_:)))
        stack.addArrangedSubview(scrollFrozenDetectionCheckbox)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        finalizeSettingsStack(scroll: scroll, stack: stack)
        return scroll
    }

    private func makeCaptureMenuOrderView() -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rows)
        captureMenuOrderRowsStack = rows

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            rows.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])

        rebuildCaptureMenuOrderRows()
        return box
    }

    private func rebuildCaptureMenuOrderRows() {
        guard let rows = captureMenuOrderRowsStack else { return }
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, itemID) in captureMenuOrder.enumerated() {
            let icon = NSImageView(image: NSImage(systemSymbolName: itemID.symbolName, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let label = NSTextField(labelWithString: itemID.title)
            label.font = NSFont.systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let spacer = NSView()

            let upButton = captureMenuOrderButton(
                symbolName: "chevron.up",
                action: #selector(moveCaptureMenuItemUp(_:)),
                tag: index,
                toolTip: L("Move up"))
            upButton.isEnabled = index > 0

            let downButton = captureMenuOrderButton(
                symbolName: "chevron.down",
                action: #selector(moveCaptureMenuItemDown(_:)),
                tag: index,
                toolTip: L("Move down"))
            downButton.isEnabled = index < captureMenuOrder.count - 1

            let row = NSStackView(views: [icon, label, spacer, upButton, downButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true

            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func captureMenuOrderButton(symbolName: String, action: Selector, tag: Int, toolTip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.tag = tag
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func saveCaptureMenuOrderAndRefreshMenu() {
        CaptureMenuItemID.saveOrder(captureMenuOrder)
        onHotkeyChanged?()
    }

    @objc private func moveCaptureMenuItemUp(_ sender: NSButton) {
        let index = sender.tag
        guard index > 0, index < captureMenuOrder.count else { return }
        captureMenuOrder.swapAt(index, index - 1)
        rebuildCaptureMenuOrderRows()
        saveCaptureMenuOrderAndRefreshMenu()
    }

    @objc private func moveCaptureMenuItemDown(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < captureMenuOrder.count - 1 else { return }
        captureMenuOrder.swapAt(index, index + 1)
        rebuildCaptureMenuOrderRows()
        saveCaptureMenuOrderAndRefreshMenu()
    }

    @objc private func resetCaptureMenuOrder(_ sender: NSButton) {
        CaptureMenuItemID.resetOrder()
        captureMenuOrder = CaptureMenuItemID.defaultOrder
        rebuildCaptureMenuOrderRows()
        onHotkeyChanged?()
    }

    // MARK: - Shortcuts Tab

    private func makeShortcutsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        stack.addArrangedSubview(sectionHeader(L("Keyboard Shortcuts")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for slot in HotkeyManager.HotkeySlot.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.stringValue = HotkeyManager.displayString(for: slot)

            let btn = NSButton(title: L("Set"), target: self, action: #selector(recordShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = slot.rawValue

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = slot.rawValue
            clearBtn.toolTip = L("None")
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetBtn = NSButton(title: "", target: self, action: #selector(resetShortcut(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.isBordered = false
            resetBtn.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetBtn.contentTintColor = .secondaryLabelColor
            resetBtn.imagePosition = .imageOnly
            resetBtn.tag = slot.rawValue
            resetBtn.toolTip = L("Reset to default")
            resetBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            hotkeyFields[slot] = field
            hotkeyButtons[slot] = btn

            stack.addArrangedSubview(labeledRow("\(slot.label):", controls: [field, btn, clearBtn, resetBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let note = NSTextField(wrappingLabelWithString: L("Click \"Set\" and press a key combination with at least one modifier (⌘, ⌥, ⌃, ⇧) to set a shortcut."))
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(note))

        // ── Undo / Redo command shortcuts ───────────────────
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionHeader("\(L("Undo")) / \(L("Redo"))"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for action in EditorCommandShortcutManager.Action.allCases {
            let index = EditorCommandShortcutManager.Action.allCases.firstIndex(of: action)!
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
            field.stringValue = EditorCommandShortcutManager.displayString(for: action)

            let button = NSButton(title: L("Set"), target: self, action: #selector(recordCommandShortcut(_:)))
            button.bezelStyle = .rounded
            button.tag = index

            let clearButton = NSButton(title: "", target: self, action: #selector(clearCommandShortcut(_:)))
            clearButton.bezelStyle = .inline
            clearButton.isBordered = false
            clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearButton.contentTintColor = .secondaryLabelColor
            clearButton.imagePosition = .imageOnly
            clearButton.tag = index
            clearButton.toolTip = L("None")
            clearButton.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetButton = NSButton(title: "", target: self, action: #selector(resetCommandShortcut(_:)))
            resetButton.bezelStyle = .inline
            resetButton.isBordered = false
            resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetButton.contentTintColor = .secondaryLabelColor
            resetButton.imagePosition = .imageOnly
            resetButton.tag = index
            resetButton.toolTip = L("Reset to default")
            resetButton.widthAnchor.constraint(equalToConstant: 20).isActive = true

            commandShortcutFields[action] = field
            commandShortcutButtons[action] = button
            stack.addArrangedSubview(labeledRow("\(action.label):", controls: [field, button, clearButton, resetButton]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        // ── Overlay / Editor Tool Shortcuts ──────────────────
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionHeader(L("Overlay / Editor Shortcuts")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        showToolShortcutsInTooltipsCheckbox = NSButton(
            checkboxWithTitle: L("Show shortcuts in tooltips"),
            target: self,
            action: #selector(showToolShortcutsInTooltipsChanged(_:)))
        stack.addArrangedSubview(indented(showToolShortcutsInTooltipsCheckbox))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        for action in ToolShortcutManager.Action.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.stringValue = ToolShortcutManager.displayString(for: action)

            let btn = NSButton(title: L("Set"), target: self, action: #selector(recordToolShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearToolShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!
            clearBtn.toolTip = L("None")
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetBtn = NSButton(title: "", target: self, action: #selector(resetToolShortcut(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.isBordered = false
            resetBtn.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetBtn.contentTintColor = .secondaryLabelColor
            resetBtn.imagePosition = .imageOnly
            resetBtn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!
            resetBtn.toolTip = L("Reset to default")
            resetBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            toolShortcutFields[action] = field
            toolShortcutButtons[action] = btn

            stack.addArrangedSubview(labeledRow("\(action.label):", controls: [field, btn, clearBtn, resetBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        let toolNote = NSTextField(wrappingLabelWithString: L("Press a single key to assign it as the shortcut for that tool. These work when the overlay or editor is active."))
        toolNote.font = NSFont.systemFont(ofSize: 10)
        toolNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(toolNote))

        // Spacer to push content to top
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        stack.addArrangedSubview(spacer)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor),
        ])

        return scroll
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }

        // If already recording this slot, stop
        if recordingSlot == slot {
            stopShortcutRecording()
            return
        }
        // Stop any previous recording.
        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()

        recordingSlot = slot
        sender.title = L("Press keys...")
        hotkeyFields[slot]?.stringValue = L("Waiting...")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 {
                self.stopShortcutRecording()
                return nil
            }
            let modifiers = event.modifierFlags
            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)
            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) { return nil }
            HotkeyManager.saveHotkey(for: slot, keyCode: keyCode, modifiers: carbonMods)
            self.hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
            self.stopShortcutRecording()
            self.onHotkeyChanged?()
            return nil
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.disableHotkey(for: slot)
        hotkeyFields[slot]?.stringValue = L("None")
        onHotkeyChanged?()
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.saveHotkey(for: slot, keyCode: slot.defaultKeyCode, modifiers: slot.defaultModifiers)
        hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        onHotkeyChanged?()
    }

    private func stopShortcutRecording() {
        if let slot = recordingSlot {
            hotkeyButtons[slot]?.title = L("Set")
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        recordingSlot = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Editor Command Shortcuts

    @objc private func recordCommandShortcut(_ sender: NSButton) {
        let actions = EditorCommandShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        if recordingCommandAction == action {
            stopCommandShortcutRecording()
            return
        }

        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()
        recordingCommandAction = action
        sender.title = L("Press keys...")
        commandShortcutFields[action]?.stringValue = L("Waiting...")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stopCommandShortcutRecording()
                return nil
            }
            let modifiers = KeyboardShortcutMatcher.modifiers(in: event)
            // Editor commands are menu key equivalents, so require Command;
            // Shift/Option/Control may be added to distinguish the chord.
            guard modifiers.contains(.command),
                  let character = KeyboardShortcutMatcher.semanticCharacter(for: event) else {
                return nil
            }
            let shortcut = EditorCommandShortcutManager.Shortcut(
                character: character,
                modifiers: modifiers)
            EditorCommandShortcutManager.setShortcut(shortcut, for: action)
            self.stopCommandShortcutRecording()
            self.refreshShortcutDisplaysForKeyboardLayout()
            self.onEditorCommandShortcutChanged?()
            return nil
        }
    }

    @objc private func clearCommandShortcut(_ sender: NSButton) {
        let actions = EditorCommandShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        stopCommandShortcutRecording()
        EditorCommandShortcutManager.disable(action)
        commandShortcutFields[action]?.stringValue = L("None")
        onEditorCommandShortcutChanged?()
    }

    @objc private func resetCommandShortcut(_ sender: NSButton) {
        let actions = EditorCommandShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        stopCommandShortcutRecording()
        EditorCommandShortcutManager.reset(action)
        commandShortcutFields[action]?.stringValue = EditorCommandShortcutManager.displayString(for: action)
        onEditorCommandShortcutChanged?()
    }

    private func stopCommandShortcutRecording() {
        if let action = recordingCommandAction {
            commandShortcutFields[action]?.stringValue = EditorCommandShortcutManager.displayString(for: action)
            commandShortcutButtons[action]?.title = L("Set")
        }
        recordingCommandAction = nil
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
    }

    // MARK: - Overlay Tool Shortcuts

    @objc private func recordToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]

        // If already recording this action, stop
        if recordingToolAction == action {
            stopToolShortcutRecording()
            return
        }
        // Stop any other recording.
        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()

        recordingToolAction = action
        sender.title = L("Press...")
        toolShortcutFields[action]?.stringValue = "…"

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Only accept single keys without modifiers (or allow Escape to cancel)
            if event.keyCode == 53 { // Escape — cancel
                self.stopToolShortcutRecording()
                return nil
            }
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control),
                  let char = KeyboardShortcutMatcher.semanticCharacter(for: event) else { return nil }

            ToolShortcutManager.setKey(char, for: action)
            self.toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            self.stopToolShortcutRecording()
            return nil
        }
    }

    @objc private func clearToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey("", for: action)
        toolShortcutFields[action]?.stringValue = L("None")
    }

    @objc private func resetToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey(action.defaultKey, for: action)
        toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
    }

    @objc private func showToolShortcutsInTooltipsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showToolShortcutsInTooltips")
    }

    private func stopToolShortcutRecording() {
        if let action = recordingToolAction {
            toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            toolShortcutButtons[action]?.title = L("Set")
        }
        recordingToolAction = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Tools Tab

    private func makeToolsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Annotation Tools ─────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Annotation Tools")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteA = NSTextField(labelWithString: L("Hidden tools are removed from the bottom toolbar."))
        noteA.font = NSFont.systemFont(ofSize: 11)
        noteA.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteA)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let annotationTools: [(AnnotationTool, String)] = [
            (.pencil, L("Pencil")), (.line, L("Line")), (.arrow, L("Arrow")),
            (.rectangle, L("Rectangle")),
            (.ellipse, L("Ellipse")), (.marker, L("Marker")), (.text, L("Text")),
            (.number, L("Number / Counter")), (.pixelate, L("Censor")),
            (.highlight, L("Highlight (Spotlight)")),
            (.loupe, L("Magnify (Loupe)")), (.stamp, L("Stamp / Emoji")), (.colorSampler, L("Color Picker")), (.measure, L("Measure")),
        ]
        let enabledTools = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let toolsGrid = makeToggleGrid(items: annotationTools.map { (tag: $0.rawValue, label: $1) },
                                       defaultsKey: "enabledTools", enabledValues: enabledTools)
        stack.addArrangedSubview(toolsGrid)
        toolsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Bottom Toolbar Actions ───────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Bottom Toolbar Actions")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteB = NSTextField(labelWithString: L("Hidden actions are removed from the bottom toolbar."))
        noteB.font = NSFont.systemFont(ofSize: 11)
        noteB.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteB)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let bottomActionItems = ToolbarCustomAction.bottomSettingsActions.map {
            (tag: $0.rawValue, label: $0.settingsLabel)
        }
        let enabledActions = UserDefaults.standard.array(forKey: "enabledActions") as? [Int]
        let bottomActionsGrid = makeToggleGrid(items: bottomActionItems,
                                               defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(bottomActionsGrid)
        bottomActionsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Right Toolbar Actions ────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Right Toolbar Actions")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteC = NSTextField(labelWithString: L("Hidden actions are removed from the right toolbar."))
        noteC.font = NSFont.systemFont(ofSize: 11)
        noteC.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteC)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let rightActionItems = ToolbarCustomAction.rightSettingsActions.map {
            (tag: $0.rawValue, label: $0.settingsLabel)
        }
        let rightActionsGrid = makeToggleGrid(items: rightActionItems,
                                              defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(rightActionsGrid)
        rightActionsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        return scroll
    }

    // MARK: - About Tab

    private func makeAboutTabView() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])

        // App icon
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(12, after: icon)

        // App name
        let name = NSTextField(labelWithString: BuildVariant.displayName)
        name.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        name.textColor = .labelColor
        stack.addArrangedSubview(name)

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: String(format: L("Version %@ (%@)"), version, build))
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)
        stack.setCustomSpacing(20, after: versionLabel)

        // Description
        let desc = NSTextField(wrappingLabelWithString: L("A free, open-source screenshot tool for macOS.\nFully native — built with Swift and AppKit."))
        desc.font = NSFont.systemFont(ofSize: 13)
        desc.textColor = .labelColor
        desc.alignment = .center
        stack.addArrangedSubview(desc)
        stack.setCustomSpacing(20, after: desc)

        #if OFFLINE
        let offlineNote = NSTextField(wrappingLabelWithString: L("Offline build: upload and cloud storage integrations are removed. Update checks may still connect to MacShot's update server. Screenshots and recordings stay local unless you share or save them yourself."))
        offlineNote.font = NSFont.systemFont(ofSize: 12)
        offlineNote.textColor = .secondaryLabelColor
        offlineNote.alignment = .center
        stack.addArrangedSubview(offlineNote)
        stack.setCustomSpacing(20, after: offlineNote)
        #endif

        // License
        let license = NSTextField(labelWithString: L("Licensed under the GPLv3"))
        license.font = NSFont.systemFont(ofSize: 11)
        license.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(license)
        stack.setCustomSpacing(20, after: license)

        // Screen Info (debug) — gathers display & capture metadata, copies to clipboard
        let screenInfoBtn = NSButton(title: L("Copy Screen Info"), target: self, action: #selector(copyScreenInfo))
        screenInfoBtn.bezelStyle = .rounded
        screenInfoBtn.font = NSFont.systemFont(ofSize: 11)
        screenInfoBtn.tag = 9999  // tag for lookup in action handler
        stack.addArrangedSubview(screenInfoBtn)

        let screenInfoHint = NSTextField(labelWithString: L("Copies display and capture diagnostics to clipboard"))
        screenInfoHint.font = NSFont.systemFont(ofSize: 10)
        screenInfoHint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(screenInfoHint)

        return container
    }

    @objc private func copyScreenInfo() {
        if #available(macOS 14.0, *) {
            Task { @MainActor in
                var lines: [String] = []
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                lines.append("macshot \(version) (\(build))")
                lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                lines.append("")
                lines.append("=== NSScreen Info ===")
                for (i, screen) in NSScreen.screens.enumerated() {
                    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                    let cs = screen.colorSpace?.cgColorSpace
                    // CGDisplayCopyColorSpace reads the display ICC profile directly,
                    // bypassing NSScreen — helps diagnose DisplayLink/driver issues.
                    let cgCS = CGDisplayCopyColorSpace(id)
                    lines.append("Screen \(i): \(screen.localizedName) (ID: \(id))")
                    lines.append("  frame: \(screen.frame)")
                    lines.append("  backingScale: \(screen.backingScaleFactor)")
                    lines.append("  NSScreen.colorSpace: \(cs?.name as String? ?? "nil")")
                    lines.append("  CGDisplayCopyColorSpace: \(cgCS.name as String? ?? "nil")")
                    lines.append("  cs model: \(cs?.model.rawValue ?? -1)")
                    lines.append("")
                }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    lines.append("=== ScreenCaptureKit Capture Info ===")
                    for display in content.displays {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = display.width
                        config.height = display.height
                        config.captureResolution = .best
                        config.colorSpaceName = CGColorSpace.sRGB as CFString
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            lines.append("Display \(display.displayID) (\(display.width)x\(display.height)):")
                            lines.append("  CGImage size: \(img.width)x\(img.height)")
                            lines.append("  bitsPerComponent: \(img.bitsPerComponent)")
                            lines.append("  bitsPerPixel: \(img.bitsPerPixel)")
                            lines.append("  bytesPerRow: \(img.bytesPerRow)")
                            lines.append("  bitmapInfo: \(img.bitmapInfo.rawValue)")
                            lines.append("  alphaInfo: \(img.alphaInfo.rawValue)")
                            lines.append("  colorSpace: \(img.colorSpace?.name as String? ?? "nil")")
                            lines.append("  cs model: \(img.colorSpace?.model.rawValue ?? -1)")
                            lines.append("")
                        }
                    }
                } catch {
                    lines.append("Capture error: \(error.localizedDescription)")
                }
                let result = lines.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                // Flash the button title to confirm
                if let btn = self.window?.contentView?.viewWithTag(9999) as? NSButton {
                    btn.title = L("Copied!")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { btn.title = L("Copy Screen Info") }
                }
            }
        }
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    /// Width of the right-aligned label column for `labeledRow`. Wide
    /// enough to fit the longest localized string in practice — Polish's
    /// "Szybkie przechwycenie:" (issue #130) used to get clipped at the
    /// old 140pt column. 180pt covers every shipping locale with a bit
    /// of headroom.
    private static let labelColumnWidth: CGFloat = 180

    /// A horizontal row: right-aligned label on the left, controls on the right.
    private func labeledRow(_ labelText: String, controls: [NSView]) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

        let row = NSStackView(views: [lbl] + controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Indents a view to align with the control column.
    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Label column + row spacing (8pt).
        spacer.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth + 8).isActive = true

        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Two-column grid of checkboxes in a rounded box, fills parent width.
    private func makeToggleGrid(items: [(tag: Int, label: String)],
                                 defaultsKey: String,
                                 enabledValues: [Int]?) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        // Build rows of 2 columns using horizontal stack views inside a vertical stack
        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(vStack)

        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: box.topAnchor, constant: pad),
            vStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
            vStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
            vStack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
        ])

        let cols = 2
        let rows = Int(ceil(Double(items.count) / Double(cols)))

        for row in 0..<rows {
            let hStack = NSStackView()
            hStack.orientation = .horizontal
            hStack.distribution = .fillEqually
            hStack.spacing = 0
            hStack.translatesAutoresizingMaskIntoConstraints = false
            // Row must be AT LEAST 28pt so single-line checkboxes still look
            // consistent, but can grow if a translated label wraps to two
            // lines. Without this relaxation, long locale strings get
            // horizontally clipped (issue #130).
            hStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

            for col in 0..<cols {
                let idx = row * cols + col
                if idx < items.count {
                    let item = items[idx]
                    let isEnabled = enabledValues == nil || enabledValues!.contains(item.tag)
                    let cb = NSButton(checkboxWithTitle: item.label, target: self, action: #selector(toggleItemChanged(_:)))
                    cb.state = isEnabled ? .on : .off
                    cb.tag = item.tag
                    cb.identifier = NSUserInterfaceItemIdentifier(defaultsKey)
                    cb.translatesAutoresizingMaskIntoConstraints = false
                    // Let the title wrap when it doesn't fit the column —
                    // the native NSButton checkbox truncates by default.
                    // Word-wrap is graceful; the cell takes a second line
                    // of text when needed instead of swallowing characters.
                    cb.cell?.wraps = true
                    cb.cell?.isScrollable = false
                    cb.cell?.lineBreakMode = .byWordWrapping
                    if let cell = cb.cell as? NSButtonCell {
                        cell.usesSingleLineMode = false
                    }
                    hStack.addArrangedSubview(cb)
                } else {
                    let filler = NSView()
                    filler.translatesAutoresizingMaskIntoConstraints = false
                    hStack.addArrangedSubview(filler)
                }
            }
            vStack.addArrangedSubview(hStack)
            // Stretch row to fill the vStack's width (must be after addArrangedSubview
            // so both views share a common ancestor)
            hStack.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        }

        return box
    }

    // MARK: - Load settings

    func refreshShortcutDisplaysForKeyboardLayout() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        for action in EditorCommandShortcutManager.Action.allCases {
            commandShortcutFields[action]?.stringValue = EditorCommandShortcutManager.displayString(for: action)
        }
    }

    private func loadSettings() {
        // Load shortcut fields
        refreshShortcutDisplaysForKeyboardLayout()

        savePathField.stringValue = SaveDirectoryAccess.displayPath
        selectSaveAction(SaveActionPreference.current)

        // Migrate legacy bool to new int setting
        if UserDefaults.standard.object(forKey: "ocrAction") == nil {
            let legacyAutoCopy = UserDefaults.standard.object(forKey: "autoCopyOCRText") as? Bool ?? true
            UserDefaults.standard.set(legacyAutoCopy ? 0 : 1, forKey: "ocrAction")
        }
        ocrActionPopup.selectItem(at: UserDefaults.standard.integer(forKey: "ocrAction"))
        captureMenuOrder = CaptureMenuItemID.orderedItems()
        rebuildCaptureMenuOrderRows()

        let copySound = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        copySoundCheckbox.state = copySound ? .on : .off

        // rememberSelectionCheckbox removed

        let rememberTool = UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
        rememberToolCheckbox.state = rememberTool ? .on : .off

        let thumbnail = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        thumbnailCheckbox.state = thumbnail ? .on : .off
        thumbnailLetterboxCheckbox.state = UserDefaults.standard.bool(forKey: "thumbnailLetterbox") ? .on : .off

        let autoDismiss = UserDefaults.standard.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        thumbnailAutoDismissField.integerValue = autoDismiss
        thumbnailAutoDismissStepper.integerValue = autoDismiss

        let stacking = UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool ?? true
        thumbnailStackingPopup.selectItem(at: stacking ? 0 : 1)

        let thumbnailCorner = UserDefaults.standard.string(forKey: "thumbnailCorner") ?? "bottomRight"
        switch thumbnailCorner {
        case "bottomLeft": thumbnailCornerPopup.selectItem(at: 1)
        case "topRight": thumbnailCornerPopup.selectItem(at: 2)
        case "topLeft": thumbnailCornerPopup.selectItem(at: 3)
        default: thumbnailCornerPopup.selectItem(at: 0)
        }

        let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        launchAtLoginCheckbox.state = launchAtLogin ? .on : .off

        hideMenuBarIconCheckbox.state = UserDefaults.standard.bool(forKey: "hideMenuBarIcon") ? .on : .off

        let snapGuides = UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
        snapGuidesCheckbox.state = snapGuides ? .on : .off
        let boundarySnap = UserDefaults.standard.object(forKey: "boundarySnapEnabled") as? Bool ?? true
        boundarySnapCheckbox.state = boundarySnap ? .on : .off
        let browserElementSnap = UserDefaults.standard.object(
            forKey: OverlayView.browserElementSnapEnabledKey) as? Bool ?? true
        browserElementSnapCheckbox.state = browserElementSnap ? .on : .off
        showToolShortcutsInTooltipsCheckbox.state = UserDefaults.standard.bool(forKey: "showToolShortcutsInTooltips") ? .on : .off

        captureCursorCheckbox.state = UserDefaults.standard.bool(forKey: "captureCursor") ? .on : .off
        doubleClickToCopyCheckbox.state = (UserDefaults.standard.object(forKey: "doubleClickToCopy") as? Bool ?? true) ? .on : .off
        hideCaptureInstructionsCheckbox.state = UserDefaults.standard.bool(forKey: "hideCaptureInstructions") ? .on : .off
        disableSelectionShadowCheckbox.state = UserDefaults.standard.bool(forKey: "disableSelectionOutsideShadow") ? .on : .off
        filenameTemplateField.stringValue = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        updateFilenamePreview()

        let autoUpdate = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        autoUpdateCheckbox.state = autoUpdate ? .on : .off

        betaUpdateCheckbox.state = UserDefaults.standard.bool(forKey: "betaUpdatesEnabled") ? .on : .off

        accentColorWell.color = ToolbarLayout.accentColor
        iconColorWell.color = ToolbarLayout.iconColor
        bgColorWell.color = ToolbarLayout.bgColor

        // Migrate old bool setting to new int: 0=save, 1=copy, 2=both
        if let oldBool = UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool {
            let mode = oldBool ? 1 : 0
            // If old autoCopy was on + save mode, migrate to "both"
            let hadAutoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
            let migratedMode = (!oldBool && hadAutoCopy) ? 2 : mode
            UserDefaults.standard.set(migratedMode, forKey: "quickCaptureMode")
            UserDefaults.standard.removeObject(forKey: "quickModeCopyToClipboard")
            UserDefaults.standard.removeObject(forKey: "autoCopyToClipboard")
        }
        let quickMode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
        quickModePopup.selectItem(at: quickMode)
        quickCaptureOpenEditorCheckbox.state = UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") ? .on : .off
        closeEditorAfterCopyCheckbox.state = UserDefaults.standard.bool(forKey: "closeEditorAfterCopy") ? .on : .off

        selectImageFormat(ImageEncoder.format)

        let quality = Int(ImageEncoder.quality * 100)
        qualitySlider.integerValue = quality
        qualityLabel.stringValue = String(format: L("%d%%"), quality)

        downscaleRetinaCheckbox.state = ImageEncoder.downscaleRetina ? .on : .off
        updateQualityVisibility()

        // Scroll Capture
        let autoScroll = UserDefaults.standard.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        scrollAutoScrollCheckbox.state = autoScroll ? .on : .off
        let speed = UserDefaults.standard.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        scrollSpeedPopup.selectItem(at: max(0, min(3, speed - 1)))
        scrollSpeedPopup.isEnabled = autoScroll
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        scrollMaxHeightField.integerValue = maxH
        scrollMaxHeightStepper.integerValue = maxH
        let frozenDetect = UserDefaults.standard.object(forKey: "scrollFrozenDetection") as? Bool ?? true
        scrollFrozenDetectionCheckbox.state = frozenDetect ? .on : .off
    }

    private func updateQualityVisibility() {
        let raw = imageFormatPopup.selectedItem?.representedObject as? String
        let hasQuality = raw.flatMap(ImageEncoder.Format.init(rawValue:))?.hasQuality ?? false
        qualitySlider.isEnabled = hasQuality
        qualityLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
        qualityRowLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
    }

    private func selectImageFormat(_ format: ImageEncoder.Format) {
        for item in imageFormatPopup.itemArray {
            if item.representedObject as? String == format.rawValue {
                imageFormatPopup.select(item)
                return
            }
        }
        imageFormatPopup.selectItem(at: 0)
    }

    private func selectSaveAction(_ action: SaveActionPreference) {
        for item in saveActionPopup.itemArray {
            if item.representedObject as? Int == action.rawValue {
                saveActionPopup.select(item)
                return
            }
        }
        saveActionPopup.selectItem(at: 0)
    }

    // MARK: - Actions

    @objc private func browseSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.save(url: url)
            self?.savePathField.stringValue = url.path
        }
    }

    @objc private func ocrActionChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "ocrAction")
    }
    @objc private func saveActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? Int,
              let action = SaveActionPreference(rawValue: raw) else { return }
        SaveActionPreference.current = action
    }
    @objc private func copySoundChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "playCopySound")
    }
    @objc private func rememberToolChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "rememberLastTool")
        if !enabled {
            OverlayView.resetRememberedTool()
        }
    }
    @objc private func thumbnailChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showFloatingThumbnail")
    }
    @objc private func thumbnailAutoDismissChanged(_ sender: NSStepper) {
        thumbnailAutoDismissField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "thumbnailAutoDismiss")
    }
    @objc private func thumbnailScaleChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "thumbnailScale")
        thumbnailScaleLabel?.stringValue = scalePercentString(sender.doubleValue)
    }
    @objc private func thumbnailLetterboxChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "thumbnailLetterbox")
    }

    private func scalePercentString(_ scale: Double) -> String {
        "\(Int(round(scale * 100)))%"
    }

    @objc private func thumbnailStackingChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 0, forKey: "thumbnailStacking")
    }
    @objc private func thumbnailCornerChanged(_ sender: NSPopUpButton) {
        let values = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "thumbnailCorner")
    }
    @objc private func quickModeChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "quickCaptureMode")
    }
    @objc private func quickCaptureOpenEditorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "quickCaptureOpenEditor")
    }
    @objc private func closeEditorAfterCopyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "closeEditorAfterCopy")
    }
    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/sw33tLie/macshot") { NSWorkspace.shared.open(url) }
    }
    @objc private func imageFormatChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let format = ImageEncoder.Format(rawValue: raw),
              ImageEncoder.isFormatAvailable(format)
        else { return }
        UserDefaults.standard.set(raw, forKey: "imageFormat")
        updateQualityVisibility()
    }
    @objc private func qualityChanged(_ sender: NSSlider) {
        qualityLabel.stringValue = String(format: L("%d%%"), sender.integerValue)
        UserDefaults.standard.set(Double(sender.integerValue) / 100.0, forKey: "imageQuality")
    }
    @objc private func downscaleRetinaChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "downscaleRetina")
    }
    // MARK: - Scroll Capture actions
    @objc private func scrollAutoScrollChanged(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "scrollAutoScrollEnabled")
        scrollSpeedPopup.isEnabled = on
    }
    @objc private func scrollSpeedChanged(_ sender: NSPopUpButton) {
        // 0=Slow(1), 1=Medium(2), 2=Fast(3), 3=VeryFast(4)
        UserDefaults.standard.set(sender.indexOfSelectedItem + 1, forKey: "scrollAutoScrollSpeed")
    }
    @objc private func scrollMaxHeightChanged(_ sender: NSStepper) {
        scrollMaxHeightField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "scrollMaxHeight")
    }
    @objc private func scrollFrozenDetectionChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "scrollFrozenDetection")
    }
    @objc private func toggleItemChanged(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? "enabledTools"
        let allTools: [AnnotationTool] = [.pencil, .line, .arrow, .rectangle,
                                          .ellipse, .marker, .text, .number, .pixelate, .highlight, .loupe, .stamp, .measure]
        let defaultValues: [Int] = key == "enabledTools" ? allTools.map { $0.rawValue } : ToolbarActionPreferences.defaultEnabledRawValues
        var enabled = UserDefaults.standard.array(forKey: key) as? [Int] ?? defaultValues
        if sender.state == .on { if !enabled.contains(sender.tag) { enabled.append(sender.tag) } }
        else { enabled.removeAll { $0 == sender.tag } }
        UserDefaults.standard.set(enabled, forKey: key)
    }
    @objc private func accentColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveAccentColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func iconColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveIconColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func bgColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveBgColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    // MARK: - Theme presets

    private struct ThemePreset {
        let name: String
        let accent: NSColor
        let icon: NSColor
        let bg: NSColor

        static let all: [ThemePreset] = [
            ThemePreset(name: "Default",
                        accent: ToolbarLayout.defaultAccentColor,
                        icon:   ToolbarLayout.defaultIconColor,
                        bg:     ToolbarLayout.defaultBgColor),
            ThemePreset(name: "Classic",
                        accent: NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(white: 0.12, alpha: 1.0)),
            ThemePreset(name: "Ocean",
                        accent: NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.75, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1.0)),
            ThemePreset(name: "Sunset",
                        accent: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.20, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.12, alpha: 1.0)),
            ThemePreset(name: "Forest",
                        accent: NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.45, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.10, alpha: 1.0)),
            ThemePreset(name: "Mono",
                        accent: NSColor(white: 0.30, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(white: 0.10, alpha: 1.0)),
        ]
    }

    private func makeColorColumn(well: NSColorWell, caption: String) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let col = NSStackView(views: [well, label])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }

    @objc private func themePresetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        // indexOfSelectedItem is -1 with no selection, which passes "< count".
        guard idx >= 0, idx < ThemePreset.all.count else { return } // "Custom" — no-op
        applyThemePreset(ThemePreset.all[idx])
    }

    private func applyThemePreset(_ preset: ThemePreset) {
        ToolbarLayout.saveAccentColor(preset.accent)
        ToolbarLayout.saveIconColor(preset.icon)
        ToolbarLayout.saveBgColor(preset.bg)
        accentColorWell.color = preset.accent
        iconColorWell.color = preset.icon
        bgColorWell.color = preset.bg
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }

    private func updateThemePresetSelection() {
        guard let popup = themePresetPopup else { return }
        let current = (ToolbarLayout.accentColor, ToolbarLayout.iconColor, ToolbarLayout.bgColor)
        for (i, preset) in ThemePreset.all.enumerated() {
            if colorsClose(current.0, preset.accent) &&
               colorsClose(current.1, preset.icon) &&
               colorsClose(current.2, preset.bg) {
                popup.selectItem(at: i)
                return
            }
        }
        // No match — select "Custom" (the last item)
        popup.selectItem(at: ThemePreset.all.count)
    }

    /// Compare two NSColors in sRGB with a small tolerance (color picker rounding).
    private func colorsClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let tol: CGFloat = 0.01
        return abs(x.redComponent - y.redComponent) < tol
            && abs(x.greenComponent - y.greenComponent) < tol
            && abs(x.blueComponent - y.blueComponent) < tol
            && abs(x.alphaComponent - y.alphaComponent) < tol
    }
    private func notifyToolbarColorChange() {
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }
    @objc private func snapGuidesChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "snapGuidesEnabled")
    }
    @objc private func boundarySnapChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "boundarySnapEnabled")
    }
    @objc private func browserElementSnapChanged(_ sender: NSButton) {
        UserDefaults.standard.set(
            sender.state == .on,
            forKey: OverlayView.browserElementSnapEnabledKey)
    }
    @objc private func captureCursorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "captureCursor")
    }
    @objc private func doubleClickToCopyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "doubleClickToCopy")
    }
    @objc private func hideCaptureInstructionsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideCaptureInstructions")
    }
    @objc private func disableSelectionShadowChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "disableSelectionOutsideShadow")
    }
    @objc private func filenameTemplateCommitted(_ sender: NSTextField) {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? FilenameFormatter.defaultTemplate : sender.stringValue
        if trimmed.isEmpty {
            sender.stringValue = FilenameFormatter.defaultTemplate
        }
        UserDefaults.standard.set(value, forKey: FilenameFormatter.userDefaultsKey)
        updateFilenamePreview()
    }

    @objc private func filenameTemplateReset(_ sender: NSButton) {
        filenameTemplateField.stringValue = FilenameFormatter.defaultTemplate
        UserDefaults.standard.set(FilenameFormatter.defaultTemplate, forKey: FilenameFormatter.userDefaultsKey)
        updateFilenamePreview()
    }

    fileprivate func updateFilenamePreview() {
        guard let field = filenameTemplateField, let preview = filenameTemplatePreview else { return }
        let raw = field.stringValue
        let template = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FilenameFormatter.defaultTemplate : raw
        let sampleDate = sampleFilenameDate()
        let sampleWindow = template.contains("{window}") ? "Example Window" : nil
        let sampleIndex = template.contains("{index}") ? 1 : nil
        let base = FilenameFormatter.format(template: template, windowTitle: sampleWindow, index: sampleIndex, date: sampleDate)
        preview.stringValue = "\(L("Preview:")) \(base).\(ImageEncoder.fileExtension)"
    }

    private func sampleFilenameDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = 14; comps.minute = 22; comps.second = 5
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                #if DEBUG
                print("Failed to update login item: \(error)")
                #endif
            }
        }
    }

    @objc private func urlSchemeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "urlSchemeEnabled")
    }

    fileprivate var urlSchemeInfoPopover: NSPopover?
    fileprivate var filenameTemplateInfoPopover: NSPopover?

    fileprivate func showURLSchemeInfoPopover(near sourceView: NSView) {
        if let existing = urlSchemeInfoPopover, existing.isShown { return }

        let commands: [(String, String)] = [
            ("macshot://capture",             L("Start area capture")),
            ("macshot://capture-fullscreen",  L("Capture the full screen")),
            ("macshot://capture-last",        L("Re-capture the last selected area")),
            ("macshot://quick-capture",       L("Quick capture (uses your Enter action)")),
            ("macshot://ocr",                 L("Capture area and read text/QR codes")),
            ("macshot://scroll-capture",      L("Start scroll capture")),
            ("macshot://settings",            L("Open this settings window")),
            ("macshot://open?file=/path.png", L("Open an image file in the editor")),
        ]

        let title = NSTextField(labelWithString: L("Supported URL Scheme Commands"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("Trigger macshot from Raycast, Alfred, Shortcuts, or any tool that opens URLs."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 440
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // NSGridView for perfect column alignment — each row's cmd column and
        // desc column line up precisely regardless of text width.
        let grid = NSGridView(numberOfColumns: 2, rows: commands.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in commands.enumerated() {
            let cmdLabel = NSTextField(labelWithString: entry.0)
            cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cmdLabel.textColor = .labelColor
            cmdLabel.isSelectable = true

            let descLabel = NSTextField(labelWithString: entry.1)
            descLabel.font = NSFont.systemFont(ofSize: 11)
            descLabel.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = cmdLabel
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = descLabel
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container

        // Compute fitting size for the popover
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = fitting
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        urlSchemeInfoPopover = popover
    }

    @objc private func hideMenuBarIconChanged(_ sender: NSButton) {
        let hidden = sender.state == .on
        UserDefaults.standard.set(hidden, forKey: "hideMenuBarIcon")
        (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hidden)
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "SUEnableAutomaticChecks")
    }

    @objc private func betaUpdateChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "betaUpdatesEnabled")
    }

    func showWindow() {
        loadSettings()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}

// MARK: - NSTextFieldDelegate (live filename preview)

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === filenameTemplateField {
            // Save on every keystroke so closing the window without pressing
            // Enter doesn't silently lose the edit. Empty value resets to
            // the default template at commit time (see controlTextDidEndEditing).
            UserDefaults.standard.set(field.stringValue, forKey: FilenameFormatter.userDefaultsKey)
            updateFilenamePreview()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // On commit, replace empty/whitespace-only values with the default so
        // the user never ends up with a blank template saved.
        guard let field = obj.object as? NSTextField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if field === filenameTemplateField, trimmed.isEmpty {
            field.stringValue = FilenameFormatter.defaultTemplate
            UserDefaults.standard.set(FilenameFormatter.defaultTemplate, forKey: FilenameFormatter.userDefaultsKey)
            updateFilenamePreview()
        }
    }
}

// MARK: - Filename template info popover

extension SettingsWindowController {
    fileprivate func showFilenameTemplateInfoPopover(near sourceView: NSView) {
        if let existing = filenameTemplateInfoPopover, existing.isShown { return }

        let tokens: [(String, String)] = [
            ("{date}",      "2026-04-17"),
            ("{time}",      "14-22-05"),
            ("{timestamp}", "2026-04-17_14-22-05"),
            ("{unix}",      "1745592125"),
            ("{window}",    L("Screenshots only — captured window title (blank otherwise)")),
            ("{index}",     L("Counter for multi-screen captures")),
            ("{random}",    L("8-character random string (e.g. k3j7x9q2)")),
        ]

        let title = NSTextField(labelWithString: L("Filename Template Tokens"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("The file extension is appended automatically. Slashes and colons in {window} become dashes."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 380
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(numberOfColumns: 2, rows: tokens.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in tokens.enumerated() {
            let tok = NSTextField(labelWithString: entry.0)
            tok.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tok.textColor = .labelColor
            tok.isSelectable = true

            let desc = NSTextField(labelWithString: entry.1)
            desc.font = NSFont.systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = tok
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = desc
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container
        container.layoutSubtreeIfNeeded()
        vc.preferredContentSize = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        filenameTemplateInfoPopover = popover
    }
}
