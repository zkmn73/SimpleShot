import Cocoa

extension OverlayView {

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
}
