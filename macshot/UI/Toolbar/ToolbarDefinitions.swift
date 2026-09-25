import Cocoa

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction {
    case tool(AnnotationTool)
    case color
    case sizeDisplay
    case undo
    case redo
    case copy
    case save
    case ocr
    case cancel
    case adjustSelection
    case delayCapture
    case loupe
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let tooltip: String
    var isSelected: Bool = false
    var tintColor: NSColor = ToolbarLayout.iconColor
    var selectedTintColor: NSColor? = nil  // optional status tint that remains visible while selected
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
    var hasLeadingGap: Bool = false  // start a new group: extra space + divider before this button
}

class ToolbarLayout {

    // Fixed theme colors (Flameshot purple style) — not user-customizable.
    static let defaultAccentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static let defaultIconColor = NSColor.white
    static let defaultBgColor = NSColor(white: 0.12, alpha: 1.0)

    static var accentColor: NSColor { defaultAccentColor }
    static var iconColor: NSColor { defaultIconColor }
    static var bgColor: NSColor { defaultBgColor }
    static var handleColor: NSColor { accentColor }
    static let cornerRadius: CGFloat = 6

    /// Appearance matching the toolbar background brightness.
    /// Dark background → `.darkAqua`, light background → `.aqua`.
    static var appearance: NSAppearance? {
        let color = bgColor.usingColorSpace(.deviceRGB) ?? bgColor
        var brightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return NSAppearance(named: brightness > 0.5 ? .aqua : .darkAqua)
    }

    /// The single toolbar: Move, drawing tools, color, undo/redo, then (after a gap)
    /// Copy, Save, OCR and — overlay only — Scroll Capture, Open in Editor, Cancel.
    static func bottomButtons(
        selectedTool: AnnotationTool, selectedColor: NSColor,
        hasAnnotations: Bool = false, isRecording: Bool = false, isEditorMode: Bool = false
    ) -> [ToolbarButton] {
        // Hide the bar entirely while recording
        if isRecording { return [] }

        var buttons: [ToolbarButton] = []

        let tools: [(AnnotationTool, String, String)] = [
            (.select, "arrow.up.and.down.and.arrow.left.and.right", L("Move (drag the selection)")),
            (.pencil, "scribble", L("Pencil (Draw)")),
            (.line, "line.diagonal", L("Line")),
            (.arrow, "arrow.up.right", L("Arrow")),
            (.rectangle, "rectangle", L("Rectangle")),
            (.ellipse, "oval", L("Ellipse")),
            (.marker, {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker")),
            (.text, "textformat", L("Text")),
            (.number, "1.circle.fill", L("Number")),
            (.pixelate, "_custom.checkerboard", L("Censor (Pixelate / Blur / Solid)")),
            (.highlight, "sun.max", L("Highlight (Spotlight)")),
            (.loupe, "magnifyingglass", L("Magnify (Loupe)")),
            (.colorSampler, "eyedropper", L("Color Picker")),
            (.measure, "ruler", L("Measure (px)")),
        ]

        for (tool, symbol, tip) in tools {
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            buttons.append(btn)
        }

        // Color button
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"))
        colorBtn.bgColor = selectedColor
        buttons.append(colorBtn)

        // Undo / Redo
        buttons.append(
            ToolbarButton(
                action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo")))
        buttons.append(
            ToolbarButton(
                action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo")))

        // ── Actions ──────────────────────────────────────────
        // Copy, Save and OCR come first so the editor's bar is a prefix of the
        // overlay's; Scroll Capture, Open in Editor and Cancel exist only in the overlay.
        var actions: [ToolbarButton] = []
        actions.append(ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        var saveBtn = ToolbarButton(
            action: .save, sfSymbol: "square.and.arrow.down.fill", tooltip: saveTooltip)
        saveBtn.hasContextMenu = true
        actions.append(saveBtn)
        actions.append(ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", tooltip: L("OCR & QR")))
        if !isEditorMode {
            actions.append(
                ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", tooltip: L("Scroll Capture")))
            actions.append(
                ToolbarButton(
                    action: .detach, sfSymbol: "arrow.up.forward.app",
                    tooltip: L("Open in Editor Window")))
            actions.append(ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
        }
        actions[0].hasLeadingGap = true
        buttons.append(contentsOf: actions)

        return buttons
    }
}
