import Cocoa
import UniformTypeIdentifiers

extension OverlayView {

    func showRedactTypePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let types = AutoRedactor.redactTypeNames
        let picker = ListPickerView()
        picker.items = types.map { item in
            .init(
                title: item.label,
                isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
        }
        picker.onSelect = { [weak self] idx in
            let key = types[idx].key
            let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            UserDefaults.standard.set(!current, forKey: key)
            picker.items = types.map { item in
                .init(
                    title: item.label,
                    isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
            }
            self?.needsDisplay = true
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                in: self, preferredEdge: .maxX)
        }
    }

    func showTranslatePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let languages = TranslationService.availableLanguages
        let currentCode = TranslationService.targetLanguage

        let showPopover: ([String: Bool]?) -> Void = { [weak self] appleAvailability in
            guard let self = self else { return }
            // When Apple Translation is active, only show installed languages
            let filteredLanguages: [(code: String, name: String)]
            if let avail = appleAvailability {
                filteredLanguages = languages.filter { avail[$0.code] == true }
            } else {
                filteredLanguages = languages
            }
            let picker = ListPickerView()
            let pickerW: CGFloat = 220
            picker.frame.size.width = pickerW
            picker.items = filteredLanguages.map { lang in
                return .init(title: lang.name, isSelected: lang.code == currentCode,
                             isEnabled: true, subtitle: nil)
            }
            picker.onSelect = { [weak self] idx in
                let newCode = filteredLanguages[idx].code
                TranslationService.targetLanguage = newCode
                PopoverHelper.dismiss()
                if let self = self, self.translateEnabled {
                    self.performTranslate(targetLang: newCode)
                }
                self?.needsDisplay = true
            }

            let contentH = picker.frame.height
            let maxH: CGFloat = 350
            let popoverSize = NSSize(width: pickerW, height: min(maxH, contentH))

            let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: popoverSize))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.documentView = picker

            if let anchor = anchorView {
                PopoverHelper.show(
                    scrollView, size: popoverSize, relativeTo: anchor.bounds, of: anchor,
                    preferredEdge: .maxY)
            } else {
                PopoverHelper.showAtPoint(
                    scrollView, size: popoverSize,
                    at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                    in: self, preferredEdge: .maxX)
            }

            DispatchQueue.main.async {
                picker.scrollToSelected()
            }
        }

        // If Apple Translation is selected, check which languages are installed
        if #available(macOS 15.0, *), TranslationService.provider == .apple {
            TranslationService.checkAppleLanguageAvailability { availability in
                showPopover(availability)
            }
        } else {
            showPopover(nil)
        }
    }

    func showBeautifyGradientPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = GradientPickerView(selectedIndex: beautifyStyleIndex)
        picker.onSelect = { [weak self] idx in
            guard let self = self else { return }
            self.beautifyStyleIndex = idx
            UserDefaults.standard.set(idx, forKey: "beautifyStyleIndex")
            if idx >= 0 {
                // Gradient selected — clear custom background
                self.customBeautifyBackground = nil
            } else {
                // Custom image selected — load from storage
                self.loadCustomBeautifyBackground()
            }
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: idx)
            self.onContentChanged?()
            // Rebuild options row so blur slider appears/disappears
            self.rebuildToolbarLayout()
        }
        picker.onCustomImage = { [weak self] in
            PopoverHelper.dismiss()
            self?.pickCustomBeautifyBackground()
        }
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: picker.preferredSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: picker.preferredSize,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .minY)
        }
    }

    func pickCustomBeautifyBackground() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        // Lower overlay window level temporarily so the open panel is interactive
        let savedLevel = window?.level
        window?.level = .normal
        panel.beginSheetModal(for: window!) { [weak self] response in
            self?.window?.level = savedLevel ?? .normal
            guard let self = self, response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            // Store image data (PNG) in UserDefaults for persistence
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                UserDefaults.standard.set(pngData, forKey: "beautifyCustomBgImageData")
            }
            self.customBeautifyBackground = image
            self.prepareBeautifyBackgroundCache()
            self.beautifyStyleIndex = -1
            UserDefaults.standard.set(-1, forKey: "beautifyStyleIndex")
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: -1)
            self.rebuildToolbarLayout()
        }
    }

    func loadCustomBeautifyBackground() {
        guard let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let image = NSImage(data: data) else { return }
        customBeautifyBackground = image
        prepareBeautifyBackgroundCache()
    }

    func showEmojiPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = EmojiPickerView()
        picker.onSelectEmoji = { [weak self] emoji in
            self?.currentStampImage = StampEmojis.renderEmoji(emoji)
            self?.currentStampEmoji = emoji
            self?.needsDisplay = true
        }
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: picker.preferredSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: picker.preferredSize,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .minY)
        }
    }

    // MARK: - Auto-redact & Translate actions

    func performAutoRedact() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactPII(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactAllText() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactAllText(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactFaces() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactFaces(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactPeople() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactPeople(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func showEffectsPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let picker = EffectsPickerView(config: effectsConfig)
        picker.onConfigChanged = { [weak self] config in
            guard let self = self else { return }
            self.effectsPreset = config.preset
            self.effectsBrightness = config.brightness
            self.effectsContrast = config.contrast
            self.effectsSaturation = config.saturation
            self.effectsSharpness = config.sharpness
            UserDefaults.standard.set(config.preset.rawValue, forKey: "effectsPreset")
            UserDefaults.standard.set(Double(config.brightness), forKey: "effectsBrightness")
            UserDefaults.standard.set(Double(config.contrast), forKey: "effectsContrast")
            UserDefaults.standard.set(Double(config.saturation), forKey: "effectsSaturation")
            UserDefaults.standard.set(Double(config.sharpness), forKey: "effectsSharpness")
            self.cachedCompositedImage = nil
            self.cachedEffectsScreenshot = nil
            self.rebuildToolbarLayout()
            self.needsDisplay = true
            self.onContentChanged?()
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: size,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .maxY)
        }
    }

    func performTranslate(targetLang: String) {
        guard state == .selected, let screenshot = screenshotImage else { return }
        annotations.removeAll { $0.tool == .translateOverlay }
        isTranslating = true
        needsDisplay = true

        TranslateOverlay.translate(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            targetLang: targetLang,
            onError: { [weak self] msg in
                self?.isTranslating = false
                self?.showOverlayError(msg)
                self?.needsDisplay = true
            },
            completion: { [weak self] anns in
                guard let self = self else { return }
                self.isTranslating = false
                self.annotations.removeAll { $0.tool == .translateOverlay }
                self.annotations.append(contentsOf: anns)
                self.undoStack.append(contentsOf: anns.map { .added($0) })
                self.redoStack.removeAll()
                self.needsDisplay = true
            }
        )
    }
}
