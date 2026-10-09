import AppKit

@MainActor
final class AnnotationTextWidthHandle: NSView {
    let fromLeft: Bool
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    init(fromLeft: Bool) {
        self.fromLeft = fromLeft
        super.init(frame: .zero)
        toolTip = "拖动调整文字换行宽度，字号保持不变"
        setAccessibilityElement(true)
        setAccessibilityLabel(fromLeft ? "文字框左侧宽度控制点" : "文字框右侧宽度控制点")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        let grip = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 3, y: bounds.midY - 6, width: 6, height: 12),
                                xRadius: 2, yRadius: 2)
        NSColor.controlBackgroundColor.setFill()
        grip.fill()
        NSColor.controlAccentColor.setStroke()
        grip.lineWidth = 1.5
        grip.stroke()
    }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}

/// A native plain-text editor keeps IME composition, grapheme selection and typing undo intact.
@MainActor
final class AnnotationTextView: NSTextView {
    var annotationPasteboard: NSPasteboard = .general
    var onFinish: (() -> Void)?
    private let typingHistory = UndoManager()
    override var undoManager: UndoManager? { typingHistory }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 6, modifiers == [.command] || modifiers == [.command, .shift] {
            undoTyping(redo: modifiers.contains(.shift))
            return true
        }
        guard modifiers == [.command] else { return false }
        switch event.keyCode {
        case 0: selectAll(nil)
        case 7: cut(nil)
        case 8: copy(nil)
        case 9: paste(nil)
        case 36, 76: onFinish?()
        default: return false
        }
        return true
    }

    func undoTyping(redo: Bool) {
        breakUndoCoalescing()
        if redo { if typingHistory.canRedo { typingHistory.redo() } }
        else if typingHistory.canUndo { typingHistory.undo() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        annotationPasteboard.clearContents()
        annotationPasteboard.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
        guard let text = annotationPasteboard.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
}
